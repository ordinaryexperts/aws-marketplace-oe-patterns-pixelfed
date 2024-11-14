#!/bin/bash

# aws cloudwatch
sed -i 's/ASG_APP_LOG_GROUP_PLACEHOLDER/${AsgAppLogGroup}/g' /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
sed -i 's/ASG_SYSTEM_LOG_GROUP_PLACEHOLDER/${AsgSystemLogGroup}/g' /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# reprovision if access key is rotated
# access key serial: ${SesInstanceUserAccessKeySerial}

# apache
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/ssl/private/apache-selfsigned.key \
  -out /etc/ssl/certs/apache-selfsigned.crt \
  -subj '/CN=localhost'

mkdir -p /opt/oe/patterns

# secretsmanager
SECRET_ARN="${DbSecretArn}"
echo $SECRET_ARN > /opt/oe/patterns/secret-arn.txt
SECRET_NAME=$(aws secretsmanager list-secrets --query "SecretList[?ARN=='$SECRET_ARN'].Name" --output text)
echo $SECRET_NAME > /opt/oe/patterns/secret-name.txt

aws ssm get-parameter \
    --name "/aws/reference/secretsmanager/$SECRET_NAME" \
    --with-decryption \
    --query Parameter.Value \
| jq -r . > /opt/oe/patterns/secret.json

DB_PASSWORD=$(cat /opt/oe/patterns/secret.json | jq -r .password)
DB_USERNAME=$(cat /opt/oe/patterns/secret.json | jq -r .username)

/root/check-secrets.py ${AWS::Region} ${InstanceSecretName}

aws ssm get-parameter \
    --name "/aws/reference/secretsmanager/${InstanceSecretName}" \
    --with-decryption \
    --query Parameter.Value \
| jq -r . > /opt/oe/patterns/instance.json

ACCESS_KEY_ID=$(cat /opt/oe/patterns/instance.json | jq -r .access_key_id)
SECRET_ACCESS_KEY=$(cat /opt/oe/patterns/instance.json | jq -r .secret_access_key)
APP_KEY=$(cat /opt/oe/patterns/instance.json | jq -r .app_key)

cat <<EOF > /usr/share/webapps/pixelfed/.env
APP_NAME="${AppName}"
APP_ENV="production"
APP_KEY="$APP_KEY"
APP_DEBUG="false"

# Instance Configuration
OPEN_REGISTRATION="true"
ENFORCE_EMAIL_VERIFICATION="true"
PF_MAX_USERS="1000000"
OAUTH_ENABLED="false"

# Media Configuration
PF_OPTIMIZE_IMAGES="true"
IMAGE_QUALITY="80"
MAX_PHOTO_SIZE="15000"
MAX_CAPTION_LENGTH="500"
MAX_ALBUM_LENGTH="4"

# Instance URL Configuration
APP_URL="https://${Hostname}"
APP_DOMAIN="${Hostname}"
ADMIN_DOMAIN="${Hostname}"
SESSION_DOMAIN="${Hostname}"
TRUST_PROXIES="*"

# Database Configuration
DB_CONNECTION="mysql"
DB_HOST=${DbCluster.Endpoint.Address}
DB_PORT=${DbCluster.Endpoint.Port}
DB_DATABASE="pixelfed"
DB_USERNAME=$DB_USERNAME
DB_PASSWORD="$DB_PASSWORD"

# Redis Configuration
REDIS_CLIENT="predis"
REDIS_SCHEME="tcp"
REDIS_HOST=${RedisCluster.RedisEndpoint.Address}
REDIS_PASSWORD="null"
REDIS_PORT=${RedisCluster.RedisEndpoint.Port}

# Laravel Configuration
SESSION_DRIVER="database"
CACHE_DRIVER="redis"
QUEUE_DRIVER="redis"
BROADCAST_DRIVER="log"
LOG_CHANNEL="stack"
HORIZON_PREFIX="horizon-"

# ActivityPub Configuration
ACTIVITY_PUB="${ActivityPubEnabled}"
AP_REMOTE_FOLLOW="${ActivityPubEnabled}"
AP_INBOX="${ActivityPubEnabled}"
AP_OUTBOX="${ActivityPubEnabled}"
AP_SHAREDINBOX="${ActivityPubEnabled}"

# Experimental Configuration
EXP_EMC="true"

## Mastodon Login
PF_LOGIN_WITH_MASTODON_ENABLED="${MastodonLoginEnabled}"
PF_LOGIN_WITH_MASTODON_SKIP_EMAIL="${MastodonLoginSkipEmailVerification}"
PF_LOGIN_WITH_MASTODON_DOMAINS="${MastodonLoginCustomDomains}"
PF_LOGIN_WITH_MASTODON_ONLY_DEFAULT="${MastodonLoginOnlyDefaultDomains}"
PF_LOGIN_WITH_MASTODON_ONLY_CUSTOM="${MastodonLoginOnlyCustomDomains}"
PF_LOGIN_WITH_MASTODON_ENFORCE_MAX_USES="${MastodonLoginEnforceMaxUses}"
PF_LOGIN_WITH_MASTODON_MAX_USES_LIMIT="${MastodonLoginMaxUsesLimit}"

## Mail Configuration (Post-Installer)
MAIL_DRIVER=ses
MAIL_FROM_ADDRESS="pixelfed@${HostedZoneName}"
MAIL_FROM_NAME="${Name}"
SES_KEY="$ACCESS_KEY_ID"
SES_REGION=${AWS::Region}
SES_SECRET="$SECRET_ACCESS_KEY"

## S3 Configuration (Post-Installer)
PF_ENABLE_CLOUD=true
FILESYSTEM_DRIVER=local
FILESYSTEM_CLOUD=s3
AWS_ACCESS_KEY_ID=$ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY="$SECRET_ACCESS_KEY"
AWS_DEFAULT_REGION=${AWS::Region}
AWS_BUCKET=${AssetsBucketName}
#AWS_URL=
#AWS_ENDPOINT=
#AWS_USE_PATH_STYLE_ENDPOINT=false
EOF

cd /usr/share/webapps/pixelfed
if [ -e /data/.copy_done ]
then
    echo "directory has already been copied - removing default storage"
    rm -rf storage
    if [ $? -eq 0 ]
    then
        echo "default storage removed successfully"
    else
        echo "ERROR: failed to remove default storage"
    fi
else
    mv storage /data
    if [ $? -eq 0 ]
    then
        touch /data/.copy_done
        echo "default storage moved successfully"
    else
        echo "ERROR: failed to move default storage"
    fi
fi
ln -s /data/storage storage

php artisan migrate --force
php artisan storage:link
php artisan route:cache
php artisan view:cache
php artisan config:cache
php artisan horizon:install
php artisan horizon:publish
php artisan passport:keys
php artisan passport:install
chown www-data:www-data /usr/share/webapps/pixelfed/storage/oauth*

echo "* * * * * /usr/bin/php /usr/share/webapps/pixelfed/artisan schedule:run >> /dev/null 2>&1" >> pixelfedcron
crontab pixelfedcron
rm pixelfedcron

systemctl enable apache2 && systemctl start apache2

cat <<EOF > /etc/systemd/system/pixelfed.service
[Unit]
Description=Pixelfed task queueing via Laravel Horizon
After=network.target
Requires=apache2.service

[Service]
Type=simple
ExecStart=/usr/bin/php /usr/share/webapps/pixelfed/artisan horizon
User=www-data
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reexec
systemctl enable pixelfed && systemctl start pixelfed

success=$?
cfn-signal --exit-code $success --stack ${AWS::StackName} --resource Asg --region ${AWS::Region}
