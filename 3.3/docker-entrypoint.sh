#!/bin/bash
set -e

case "$1" in
	rails|rake|passenger)
		if [ ! -f './config/database.yml' ]; then
			if [ "$MYSQL_PORT_3306_TCP" ]; then
				: "${REDMINE_DB_MYSQL:=mysql}"
			elif [ "$POSTGRES_PORT_5432_TCP" ]; then
				: "${REDMINE_DB_POSTGRES:=postgres}"
			fi

			if [ "$REDMINE_DB_MYSQL" ]; then
				adapter='mysql2'
				host="$REDMINE_DB_MYSQL"
				: "${REDMINE_DB_PORT:=3306}"
				: "${REDMINE_DB_USERNAME:=${MYSQL_ENV_MYSQL_USER:-root}}"
				: "${REDMINE_DB_PASSWORD:=${MYSQL_ENV_MYSQL_PASSWORD:-${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-}}}"
				: "${REDMINE_DB_DATABASE:=${MYSQL_ENV_MYSQL_DATABASE:-${MYSQL_ENV_MYSQL_USER:-redmine}}}"
				: "${REDMINE_DB_ENCODING:=}"
			elif [ "$REDMINE_DB_POSTGRES" ]; then
				adapter='postgresql'
				host="$REDMINE_DB_POSTGRES"
				: "${REDMINE_DB_PORT:=5432}"
				: "${REDMINE_DB_USERNAME:=${POSTGRES_ENV_POSTGRES_USER:-postgres}}"
				: "${REDMINE_DB_PASSWORD:=${POSTGRES_ENV_POSTGRES_PASSWORD}}"
				: "${REDMINE_DB_DATABASE:=${POSTGRES_ENV_POSTGRES_DB:-${REDMINE_DB_USERNAME:-}}}"
				: "${REDMINE_DB_ENCODING:=utf8}"
			else
				echo >&2
				echo >&2 'warning: missing REDMINE_DB_MYSQL or REDMINE_DB_POSTGRES environment variables'
				echo >&2
				echo >&2 '*** Using sqlite3 as fallback. ***'
				echo >&2

				adapter='sqlite3'
				host='localhost'
				: "${REDMINE_DB_PORT:=}"
				: "${REDMINE_DB_USERNAME:=redmine}"
				: "${REDMINE_DB_PASSWORD:=}"
				: "${REDMINE_DB_DATABASE:=sqlite/redmine.db}"
				: "${REDMINE_DB_ENCODING:=utf8}"

				mkdir -p "$(dirname "$REDMINE_DB_DATABASE")"
				chown -R redmine:redmine "$(dirname "$REDMINE_DB_DATABASE")"
			fi

			REDMINE_DB_ADAPTER="$adapter"
			REDMINE_DB_HOST="$host"
			echo "$RAILS_ENV:" > config/database.yml
			for var in \
				adapter \
				host \
				port \
				username \
				password \
				database \
				encoding \
			; do
				env="REDMINE_DB_${var^^}"
				val="${!env}"
				[ -n "$val" ] || continue
				echo "  $var: \"$val\"" >> config/database.yml
			done
		fi
		
		cat > 'config/configuration.yml' <<-YML
			$RAILS_ENV:
				attachments_storage_path: $REDMINE_ATTACHMENTS_DIR
		YML


		if [ "$EMAIL_ADDRESS" ]; then
			cat >> 'config/configuration.yml' <<-YML
					email_delivery:
					delivery_method: $EMAIL_METHOD
					smtp_settings:
						address: $EMAIL_ADDRESS
						port: $EMAIL_PORT
						authentication: $EMAIL_AUTHENTICATION
						domain: $EMAIL_DOMAIN
						user_name: $EMAIL_USER_NAME
						password: $EMAIL_PASSWORD
			YML
		fi
		
		if [[ -d $REDMINE_DATA_DIR/themes ]]; then
				echo "Installing themes..."
				rsync -avq --chown=redmine:redmine $REDMINE_DATA_DIR/themes/ ${REDMINE_HOME}/redmine/public/themes/
		fi
		
		if [[ -d $REDMINE_DATA_DIR/plugins ]]; then
				echo "Installing plugins..."
				rsync -avq --chown=redmine:redmine $REDMINE_DATA_DIR/plugins/ ${REDMINE_HOME}/redmine/plugins/
		fi

		# ensure the right database adapter is active in the Gemfile.lock
		bundle install --without development test

		if [ ! -s config/secrets.yml ]; then
			if [ "$REDMINE_SECRET_KEY_BASE" ]; then
				cat > 'config/secrets.yml' <<-YML
					$RAILS_ENV:
						secret_key_base: "$REDMINE_SECRET_KEY_BASE"
				YML
			elif [ ! -f /usr/src/redmine/config/initializers/secret_token.rb ]; then
				rake generate_secret_token
			fi
		fi

		if [ "$1" != 'rake' -a -z "$REDMINE_NO_DB_MIGRATE" ]; then
			gosu redmine rake db:migrate
		fi

		chown -R redmine:redmine files log public/plugin_assets

		# remove PID file to enable restarting the container
		rm -f /usr/src/redmine/tmp/pids/server.pid

		if [ "$1" = 'passenger' ]; then
			# Don't fear the reaper.
			set -- tini -- "$@"
		fi

		set -- gosu redmine "$@"
		;;
esac

exec "$@"
