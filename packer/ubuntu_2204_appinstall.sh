#
# Pixelfed configuration
#

PIXELFED_VERSION=v0.11.8

# install apache and php
apt-get -y install            \
        apache2               \
        composer              \
        libapache2-mod-php    \
        mysql-client-8.0      \
        mysql-client-core-8.0 \
        nfs-common            \
        php8.1                \
        php8.1-apcu           \
        php8.1-bcmath         \
        php8.1-cgi            \
        php8.1-curl           \
        php8.1-dev            \
        php8.1-fpm            \
        php8.1-gd             \
        php8.1-mbstring       \
        php8.1-memcached      \
        php8.1-mysql          \
        php8.1-redis          \
        php8.1-xml            \
        php8.1-zip            \
        zlib1g-dev

# Clone pixelfed
mkdir -p /usr/share/webapps
cd /usr/share/webapps
git clone https://github.com/pixelfed/pixelfed.git pixelfed
cd pixelfed
git checkout $PIXELFED_VERSION
# # https://github.com/pixelfed/pixelfed/pull/3846
# sed -i '185,187c\                        return Storage::url($path) . "?v={$avatar->change_count}";' app/Profile.php

composer install --no-ansi --no-interaction --optimize-autoloader

chown -R www-data:www-data .
find . -type d -exec chmod 755 {} \;
find . -type f -exec chmod 644 {} \;

# configure apache
a2enmod php8.1
a2enmod rewrite
a2enmod ssl

a2dissite 000-default
cat <<EOF > /etc/apache2/sites-available/pixelfed.conf
LogFormat "{\"time\":\"%{%Y-%m-%d}tT%{%T}t.%{msec_frac}tZ\", \"process\":\"%D\", \"filename\":\"%f\", \"remoteIP\":\"%a\", \"host\":\"%V\", \"request\":\"%U\", \"query\":\"%q\", \"method\":\"%m\", \"status\":\"%>s\", \"userAgent\":\"%{User-agent}i\", \"referer\":\"%{Referer}i\"}" cloudwatch
ErrorLogFormat "{\"time\":\"%{%usec_frac}t\", \"function\":\"[%-m:%l]\", \"process\":\"[pid%P]\", \"message\":\"%M\"}"

<VirtualHost *:80>
        ServerAdmin webmaster@localhost
        DocumentRoot /usr/share/webapps/pixelfed/public

        LogLevel warn
        ErrorLog /var/log/apache2/error.log
        CustomLog /var/log/apache2/access.log cloudwatch

        RewriteEngine On
        RewriteOptions Inherit

        <Directory /usr/share/webapps/pixelfed/public>
            Options Indexes FollowSymLinks MultiViews
            AllowOverride All
            Require all granted
        </Directory>

        AddType application/x-httpd-php .php
        AddType application/x-httpd-php phtml pht php

        php_value memory_limit 128M
        php_value post_max_size 100M
        php_value upload_max_filesize 100M
</VirtualHost>
<VirtualHost *:443>
        ServerAdmin webmaster@localhost
        DocumentRoot /usr/share/webapps/pixelfed/public

        LogLevel warn
        ErrorLog /var/log/apache2/error-ssl.log
        CustomLog /var/log/apache2/access-ssl.log cloudwatch

        RewriteEngine On
        RewriteOptions Inherit

        <Directory /usr/share/webapps/pixelfed/public>
            Options Indexes FollowSymLinks MultiViews
            AllowOverride All
            Require all granted
        </Directory>

        AddType application/x-httpd-php .php
        AddType application/x-httpd-php phtml pht php

        # self-signed cert
        # real cert is managed by the ELB
        SSLEngine on
        SSLCertificateFile /etc/ssl/certs/apache-selfsigned.crt
        SSLCertificateKeyFile /etc/ssl/private/apache-selfsigned.key

        php_value memory_limit 128M
        php_value post_max_size 100M
        php_value upload_max_filesize 100M
</VirtualHost>
EOF
a2ensite pixelfed

# apache2 will be enabled / started on boot
systemctl disable apache2
