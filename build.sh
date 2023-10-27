#!/bin/bash

TIMESTART=$(date +%s%N)

# Дистрибутив от 1С
SRC=`ls Patch_SUBD_PostgreSQL*.tar.bz2`

# Временные каталоги
SRCDIR=`pwd`"/src"
PATCHDIR=`pwd`"/patch"
CURRDIR=`pwd`

#Пользователь под которым работает СУБД
PGUSER="pgmaster"
HOMEDIRPGUSER="/home/${PGUSER}"

#Количество процессоров (для make)
NPROC=`nproc --all`

PGVERSION=15.3.1

PREFIX="/opt/pg-${PGVERSION}"

#Точка монтирования раздела для хранения баз данных
#должна быть пролписана в /etc/fstab до запуска этого скрипта!
MOUNTPOINT="/mnt/pg"
DBDIR="${MOUNTPOINT}/pgdata-${PGVERSION}"

#emerge app-arch/lz4 dev-perl/IPC-Run dev-perl/GSSAPI net-nds/openldap -av

if [ -f ./${SRC} ]; then
        echo "Найден дистрибутив СУБД от 1С:" ${SRC}
        echo "Количество процессоров:" ${NPROC}

        # Если директория src найдена, то удалям
        if [ -d "${SRCDIR}" ]; then
                rm -rf ${SRCDIR}
        fi

        if [ -d "${PATCHDIR}" ]; then
                rm -rf ${PATCHDIR}
        fi

        mkdir -p ${PATCHDIR}
        tar -xf ./${SRC} -C ${PATCHDIR}

        PATCHEXTRACTDIR=`ls -d ${PATCHDIR}/*`

        if [ ! -d ${PATCHEXTRACTDIR} ]; then
                echo "Не найден каталог с извлечённым дистрибутивом от 1С"
                exit 1
        fi

        mkdir -p ${SRCDIR}
        tar -xf ${PATCHEXTRACTDIR}/postgresql-*.orig.tar.bz2 -C $SRCDIR

        cd `ls -d ${SRCDIR}/*`

        patch -p1 -g1 < ${PATCHEXTRACTDIR}/00001-1C-FULL.patch > /dev/null 2>&1

        if [ ! $? -eq 0 ]; then
                echo "Исходники не пропатчены. Выход."
                exit 1
        fi

        echo "Патч на исходники наложен."

        ./configure \
                --prefix=${PREFIX} \
                --sysconfdir=${PREFIX}/config \
                --sysconfdir=${PREFIX}/config/postgresql-common \
                --localstatedir=${PREFIX}/var \
                --with-tcl --with-perl --with-python --with-pam \
                --with-openssl --with-libxml --with-libxslt --with-extra-version=" ("`hostname`" ${PGVERSION})" \
                --enable-nls --enable-thread-safety --disable-rpath --with-uuid=e2fs --with-gnu-ld \
                --with-gssapi --with-ldap --with-pgport=5432 --enable-tap-tests --with-icu  --with-lz4 > /dev/null 2>&1
                #CFLAGS='${CFLAGS}'

        if [ ! $? -eq 0 ]; then
                echo "Конфигурация провалилась. Выход."
                exit 1
        fi

        echo "Конфигурирование удалось."

        make -j${NPROC} > /dev/null 2>&1
        if [ ! $? -eq 0 ]; then
                echo "Сборка провалилась. Выход."
                exit 1
        fi
        echo "Основная сборка завершена."

        make -C contrib -j${NPROC} > /dev/null 2>&1
        if [ ! $? -eq 0 ]; then
                echo "Сборка дополнений провалилась. Выход."
                exit 1
        fi
        echo "Сборка дополнений завершена."

        if [ ! -d "${PREFIX}" ]; then
                mkdir -p ${PREFIX}
        fi

        getent passwd ${PGUSER} > /dev/null
        if [ $? -ne 0 ]; then
                useradd -d ${HOMEDIRPGUSER} -m -s /bin/bash pgmaster > /dev/null 2>&1
                if [ $? -ne 0 ]; then
                        echo "Ошибка добавления пользователя ${PGUSER}. Выход."
                        exit 1
                fi
                echo "Создан пользователь ${PGUSER}."
        else
                echo "Пользователь ${PGUSER} уже существует."
        fi

        if [ ! -f ${HOMEDIRPGUSER}/.bash_profile ]; then
                touch ${HOMEDIRPGUSER}/.bash_profile
        fi

        if ! grep -q "${PREFIX}/bin" ${HOMEDIRPGUSER}/.bash_profile; then
                cat > ${HOMEDIRPGUSER}/.bash_profile <<EOF
export LANG=ru_RU.UTF-8
export PGPORT=5432
export PATH=${PREFIX}/bin:${PREFIX}/sbin:$PATH
export LD_LIBRARY_PATH=${PREFIX}/lib
EOF
        fi

        mount ${MOUNTPOINT} > /dev/null 2>&1
        RETMOUNT=$?
        if [ ${RETMOUNT} -ne 0 ]; then
                if [ ${RETMOUNT} -eq 32 ]; then
                        echo "Раздел для баз данных (${MOUNTPOINT}) уже примонтирован."
                fi
                if [ ${RETMOUNT} -eq 1 ]; then
                        echo "Невозможно примонтировать раздел для баз данных. Выход."
                        exit 1
                fi
        else
                echo "Раздел для баз данных ($MOUNTPOINT) успешно примонтирован."
        fi

        make install > /dev/null 2>&1
        if [ $? -ne 0 ]; then
                echo "Установка провалилась. Выход."
                exit 1
        else
                echo "Установлена основная сборка."
        fi

        make -C contrib install > /dev/null 2>&1
        if [ $? -ne 0 ]; then
                echo "Установка дополнений провалилась. Выход."
                exit 1
        else
                echo "Установлены дополнения."
        fi

        export LANG=ru_RU.UTF-8
        export PGPORT=5432
        export PATH=${PREFIX}/bin:${PREFIX}/sbin:$PATH
        export LD_LIBRARY_PATH=${PREFIX}/lib

        NEWDB=0

        if [ ! -d ${DBDIR} ]; then
                mkdir -p ${DBDIR}
                if [ $? -ne 0 ]; then
                        echo "Невозможно создать каталог баз данных ${DBDIR}."
                        exit 1
                else
                        chown ${PGUSER} ${DBDIR}
                        chmod 700 ${DBDIR}
                        echo "Каталог баз данных ($DBDIR) создан. Для пользователя ${PGUSER} права на каталог назначены"
                        sudo -u ${PGUSER} \
                                LANG=ru_RU.UTF-8 \
                                PATH=${PREFIX}/bin:${PREFIX}/sbin:$PATH \
                                LD_LIBRARY_PATH=${PREFIX}/lib \
                                ${PREFIX}/bin/initdb ${DBDIR} > /dev/null 2>&1
                        if [ $? -ne 0 ]; then
                                echo "Инициализация базы данных не выполнена! Выход."
                                exit 0
                        else
                                echo "База данных проинициализированна."
                                NEWDB=1
                        fi
                fi
        else
                echo "Каталог баз данных ${DBDIR} уже существует."
        fi

        #Если это новая база, то копируем конфиги, иначе не трогаем
        if [ ${NEWDB} -ne 0 ]; then
                if [ -f ./pg_hba.conf ]; then
                        cp -f ./pg_hba.conf ${DBDIR}/
                        if [ $? -ne 0 ]; then
                                echo "Не удалось скопировать конфиг pg_hba.conf"
                        else
                                echo "Конфиг pg_hba.conf скопирован в ${DBDIR}"
                        fi
                fi

                if [ -f ./postgresql.conf ]; then
                        cp -f ./postgresql.conf ${DBDIR}/
                        if [ $? -ne 0 ]; then
                                echo "Не удалось скопировать конфиг postgresql.conf"
                        else
                                echo "Конфиг postgresql.conf скопирован в ${DBDIR}"
                        fi
                fi
        fi

        echo ${PGVERSION} > ${MOUNTPOINT}/version

        #psql "alter user pgmaster password 'Password';"

        /etc/init.d/postgres restart

        # Добавляем глобальные функции
        sudo -u ${PGUSER} \
                LANG=ru_RU.UTF-8 \
                PATH=${PREFIX}/bin:${PREFIX}/sbin:$PATH \
                LD_LIBRARY_PATH=${PREFIX}/lib \
                ${PREFIX}/bin/psql postgres -f ./ext.sql > /dev/null 2>&1
        if [ $? -eq 0 ]; then
                echo "Функции datediff, datediff2 и plpgsql_call_handler - добавлены."
        fi
fi

TIMEEND=$(date +%s%N)
TIMEDIFF=$((($TIMEEND - $TIMESTART)/1000000))
TIMESEC=$((TIMEDIFF/1000))

echo "Время выполнения:" $(date --utc --date=@${TIMESEC} +%T)
