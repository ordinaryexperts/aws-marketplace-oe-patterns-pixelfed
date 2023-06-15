#!/bin/bash

# aws cloudwatch
cat <<EOF > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root",
    "logfile": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log"
  },
  "metrics": {
    "metrics_collected": {
      "collectd": {
        "metrics_aggregation_interval": 60
      },
      "disk": {
        "measurement": ["used_percent"],
        "metrics_collection_interval": 60,
        "resources": ["*"]
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      }
    },
    "append_dimensions": {
      "ImageId": "\${!aws:ImageId}",
      "InstanceId": "\${!aws:InstanceId}",
      "InstanceType": "\${!aws:InstanceType}",
      "AutoScalingGroupName": "\${!aws:AutoScalingGroupName}"
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/dpkg.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/dpkg.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/apt/history.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/apt/history.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/cloud-init.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/cloud-init.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/cloud-init-output.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/cloud-init-output.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/auth.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/auth.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/syslog",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/syslog",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/amazon/ssm/amazon-ssm-agent.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/amazon/ssm/amazon-ssm-agent.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/amazon/ssm/errors.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/amazon/ssm/errors.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/drupal-cache.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/drupal-cache.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/apache2/access.log",
            "log_group_name": "${AsgAppLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/apache2/access.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/apache2/error.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/apache2/error.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/apache2/access-ssl.log",
            "log_group_name": "${AsgAppLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/apache2/access-ssl.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/apache2/error-ssl.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/apache2/error-ssl.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/usr/share/webapps/pixelfed/storage/logs/laravel.log",
            "log_group_name": "${AsgAppLogGroup}",
            "log_stream_name": "{instance_id}-laravel.log",
            "timezone": "UTC"
          }
        ]
      }
    },
    "log_stream_name": "{instance_id}"
  }
}
EOF
systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

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
ACTIVITY_PUB="false"
AP_REMOTE_FOLLOW="false"
AP_INBOX="false"
AP_OUTBOX="false"
AP_SHAREDINBOX="false"

# Experimental Configuration
EXP_EMC="true"

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
