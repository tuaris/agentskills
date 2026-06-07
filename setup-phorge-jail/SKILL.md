---
name: setup-phorge-jail
description: Install and configure Phorge (Phabricator fork) in a FreeBSD jail with nginx, PHP-FPM, and MariaDB. Includes issue tracker, wiki, project boards, and repository hosting. Use when setting up project management or issue tracking on FreeBSD.
license: BSD-2-Clause
compatibility: Requires FreeBSD 14.0 or later with jail infrastructure already provisioned (see setup-freebsd-jails skill)
metadata:
  author: Daniel Morante
  version: "1.0"
  source: https://we.phorge.it/book/phorge/article/configuration_guide/
---

# Setup Phorge in a FreeBSD Jail

This skill installs Phorge (the community fork of Phabricator) inside a FreeBSD jail. Phorge provides:

- **Maniphest** — Issue/task tracker with custom fields, priorities, and workboards
- **Phriction** — Wiki/documentation with versioning
- **Projects** — Kanban boards, milestones, and subprojects
- **Diffusion** — Git/SVN repository browser
- **Differential** — Code review
- **Herald** — Automation rules
- **Dashboard** — Custom dashboards

## Prerequisites

- FreeBSD jail infrastructure already set up (see **setup-freebsd-jails** skill)
- A running MariaDB/MySQL instance accessible from the jail (can be in a separate jail or on the host)
- A reverse proxy (HAProxy, nginx, or Apache) handling TLS termination in front of the jail
- DNS configured for the Phorge hostname

## Important: Gather Information First

Before starting, ask the user for:

1. **Jail name** — e.g., `phorge`
2. **Hostname/URL** — e.g., `phorge.example.com` (the public URL users will access)
3. **Alternate file domain** (optional, recommended) — e.g., `files-phorge.example.com` (XSS isolation)
4. **MariaDB connection** — host, port, credentials (or create new)
5. **SMTP server** — for sending email notifications (host, port, auth)
6. **Timezone** — e.g., `America/New_York`
7. **Internal port** — port Apache will listen on inside the jail (default: 8083)

## Step 1: Create the Jail

Use the **setup-freebsd-jails** skill to create the jail:

```sh
create-jail -n phorge
service jail start phorge
```

## Step 2: Install Packages

```sh
pkg -j phorge install -y \
  phorgeitphorge-php84 \
  apache24 \
  php84 \
  php84-extensions \
  php84-mysqli \
  php84-mbstring \
  php84-curl \
  php84-fileinfo \
  php84-gd \
  php84-iconv \
  php84-opcache \
  php84-pcntl \
  php84-posix \
  php84-zip \
  mariadb1011-client \
  py311-pygments
```

> **Note:** Replace `php84` with the current PHP version in ports. The `phorgeitphorge-php84` metapackage pulls most dependencies, but explicitly listing ensures nothing is missed.

## Step 3: Enable PHP Extensions

```sh
jexec phorge sh -c 'for f in /usr/local/etc/php/ext-*.ini.sample; do cp "$f" "${f%.sample}"; done'
```

## Step 4: Configure PHP

```sh
jexec phorge cp /usr/local/etc/php.ini-production /usr/local/etc/php.ini
```

Edit `/usr/local/etc/php.ini` inside the jail:

```ini
date.timezone = America/New_York
post_max_size = 64M
upload_max_filesize = 64M
opcache.validate_timestamps = 0
```

## Step 5: Configure PHP-FPM

Create `/usr/local/etc/php-fpm.d/www.conf` inside the jail:

```ini
[www]
user = www
group = www
listen = /var/run/php-fpm.sock
listen.owner = www
listen.group = www
listen.mode = 0660
pm = dynamic
pm.max_children = 10
pm.start_servers = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 5
```

## Step 6: Create MariaDB Database

On the MariaDB host, create the database user and grant privileges:

```sql
CREATE USER IF NOT EXISTS 'phorge'@'localhost' IDENTIFIED BY '<password>';
GRANT ALL PRIVILEGES ON `phorge\_%`.* TO 'phorge'@'localhost';
FLUSH PRIVILEGES;
```

> **Note:** If MariaDB is in a separate jail using `ip4=inherit`, connections appear as `localhost`. If using a dedicated IP, replace `'localhost'` with the appropriate host. Remember MySQL's `%` wildcard does NOT match `localhost` — create both if needed.

Configure MariaDB for Phorge (add to a `.cnf` file):

```ini
[mysqld]
local_infile = 0
max_allowed_packet = 64M
sql_mode = STRICT_ALL_TABLES
ft_min_word_len = 3
```

Restart MariaDB after config changes.

## Step 7: Configure Phorge

Create `/usr/local/lib/php/phorge/conf/local/local.json` inside the jail:

```json
{
  "phabricator.base-uri": "https://<HOSTNAME>/",
  "mysql.host": "127.0.0.1",
  "mysql.port": 3306,
  "mysql.user": "phorge",
  "mysql.pass": "<DB_PASSWORD>",
  "storage.default-namespace": "phorge",
  "pygments.enabled": true,
  "phd.user": "www",
  "repository.default-local-path": "/var/db/phorge/repo",
  "storage.local-disk.path": "/var/db/phorge/files",
  "phabricator.timezone": "<TIMEZONE>",
  "auth.require-approval": false,
  "security.alternate-file-domain": "https://<FILES_HOSTNAME>/"
}
```

Create data directories:

```sh
jexec phorge sh -c 'mkdir -p /var/db/phorge/repo /var/db/phorge/files && chown -R www:www /var/db/phorge'
```

## Step 8: Initialize Database Schema

```sh
jexec phorge /usr/local/lib/php/phorge/bin/storage upgrade --force
```

This creates ~30 databases with the `phorge_` prefix and applies all schema migrations.

## Step 9: Configure Apache

Disable the default Listen 80 and create a Phorge VirtualHost. First, edit `/usr/local/etc/apache24/httpd.conf` inside the jail:

```sh
# Comment out default Listen 80
jexec phorge sed -i "" 's/^Listen 80$/#Listen 80/' /usr/local/etc/apache24/httpd.conf

# Enable required modules
jexec phorge sed -i "" 's/^#LoadModule rewrite_module/LoadModule rewrite_module/' /usr/local/etc/apache24/httpd.conf
jexec phorge sed -i "" 's/^#LoadModule proxy_module/LoadModule proxy_module/' /usr/local/etc/apache24/httpd.conf
jexec phorge sed -i "" 's/^#LoadModule proxy_fcgi_module/LoadModule proxy_fcgi_module/' /usr/local/etc/apache24/httpd.conf
```

Create `/usr/local/etc/apache24/Includes/phorge.conf` inside the jail:

```apache
Listen <INTERNAL_PORT>

<VirtualHost *:<INTERNAL_PORT>>
    ServerName <HOSTNAME>
    ServerAlias <FILES_HOSTNAME>
    DocumentRoot /usr/local/lib/php/phorge/webroot

    RewriteEngine on
    RewriteRule ^/rsrc/(.*) - [L,QSA]
    RewriteRule ^/favicon.ico - [L,QSA]
    RewriteRule ^(.*)$ /index.php?__path__=$1 [B,L,QSA]

    <Directory "/usr/local/lib/php/phorge/webroot">
        Require all granted
    </Directory>

    <FilesMatch "\.php$">
        SetHandler "proxy:unix:/var/run/php-fpm.sock|fcgi://localhost"
    </FilesMatch>

    SetEnv HTTPS on

    # Increase limits for file uploads
    LimitRequestBody 67108864
</VirtualHost>
```

> **Important:** `SetEnv HTTPS on` tells Phorge it's behind a TLS-terminating reverse proxy so it generates correct `https://` URLs.

## Step 10: Enable Password Auth Provider

Phorge requires at least one auth provider. Insert the password provider:

```sh
jexec phorge sh -c 'mysql -u phorge -p<DB_PASSWORD> -h 127.0.0.1 phorge_auth -e \
  "INSERT INTO auth_providerconfig (phid, providerClass, providerType, providerDomain, isEnabled, shouldAllowLogin, shouldAllowRegistration, shouldAllowLink, shouldAllowUnlink, shouldTrustEmails, properties, dateCreated, dateModified, shouldAutoLogin) VALUES (\"PHID-AUTH-password001\", \"PhabricatorPasswordAuthProvider\", \"password\", \"self\", 1, 1, 1, 1, 1, 0, \"{}\", UNIX_TIMESTAMP(), UNIX_TIMESTAMP(), 0)"'
```

## Step 11: Create Admin User

```sh
jexec phorge sh -c 'cat > /tmp/create-admin.php << "SCRIPT"
<?php
require_once "/usr/local/lib/php/phorge/scripts/init/init-script.php";

$table = new PhabricatorUser();
$conn = $table->establishConnection("r");
$any = queryfx_one($conn, "SELECT id FROM %T LIMIT 1", $table->getTableName());
if ($any) { echo "Users already exist, skipping.\n"; exit(0); }

$user = new PhabricatorUser();
$user->setUsername("<ADMIN_USERNAME>");
$user->setRealName("Administrator");
$user->setIsAdmin(true);

$email = id(new PhabricatorUserEmail())
  ->setAddress("<ADMIN_EMAIL>")
  ->setIsVerified(true);

$editor = new PhabricatorUserEditor();
$editor->setActor($user);
$editor->createNewUser($user, $email);

$envelope = new PhutilOpaqueEnvelope("<ADMIN_PASSWORD>");
$password = PhabricatorAuthPassword::initializeNewPassword($user, PhabricatorAuthPassword::PASSWORD_TYPE_ACCOUNT);
$password->setPassword($envelope, $user);
$password->save();

echo "Admin user created.\n";
SCRIPT
php /tmp/create-admin.php'
```

If the user already exists but needs admin privileges:

```sh
jexec phorge sh -c 'mysql -u phorge -p<DB_PASSWORD> -h 127.0.0.1 phorge_user -e \
  "UPDATE user SET isAdmin = 1, isApproved = 1 WHERE userName = \"<ADMIN_USERNAME>\""'
```

## Step 12: Generate Recovery Link

If login isn't working or to bypass auth issues:

```sh
jexec phorge /usr/local/lib/php/phorge/bin/auth recover <ADMIN_USERNAME>
```

This prints a one-time URL that grants immediate access.

## Step 13: Enable Services

```sh
jexec phorge sysrc apache24_enable=YES
jexec phorge sysrc php_fpm_enable=YES
jexec phorge sysrc phd_enable=YES
jexec phorge service php_fpm start
jexec phorge service apache24 start
jexec phorge service phd start
```

The `phd` service runs background daemons (task workers, repository pull, triggers, fact indexing).

## Step 14: Configure Mailers

```sh
jexec phorge /usr/local/lib/php/phorge/bin/config set cluster.mailers --stdin << 'EOF'
[
  {
    "key": "smtp",
    "type": "smtp",
    "options": {
      "host": "<SMTP_HOST>",
      "port": <SMTP_PORT>,
      "protocol": "plain",
      "user": null,
      "password": null
    }
  }
]
EOF
```

Set `"protocol"` to `"tls"` or `"ssl"` if the SMTP server requires encryption. Set `"user"` and `"password"` if authentication is required.

## Step 15: Lock Auth Configuration

After verifying login works:

```sh
jexec phorge /usr/local/lib/php/phorge/bin/config set auth.lock-config true
```

## Step 16: Reverse Proxy Configuration

The jail's Apache listens on an internal port (e.g., 8083). A reverse proxy on the host handles TLS termination and routes traffic to the jail.

### HAProxy Example

```haproxy
frontend https_front
    bind *:443 ssl crt /path/to/wildcard-bundle.pem
    http-request set-header X-Forwarded-Proto https

    acl host_phorge       hdr(host) -i phorge.example.com
    acl host_phorge_files hdr(host) -i files-phorge.example.com

    use_backend phorge_back if host_phorge
    use_backend phorge_back if host_phorge_files

backend phorge_back
    server phorge 127.0.0.1:8083 check
```

## Post-Install: Useful Commands

```sh
# Check daemon status
jexec phorge /usr/local/lib/php/phorge/bin/phd status

# Restart daemons
jexec phorge service phd restart

# Run storage migrations after upgrades
jexec phorge /usr/local/lib/php/phorge/bin/storage upgrade --force

# List all config keys
jexec phorge /usr/local/lib/php/phorge/bin/config list

# Set a config value
jexec phorge /usr/local/lib/php/phorge/bin/config set <key> <value>
```

## Applications Enabled by Default

| Application | Purpose |
|-------------|---------|
| Maniphest | Issue/task tracker with priorities, assignees, custom fields |
| Phriction | Wiki with hierarchical pages and version history |
| Projects | Kanban workboards, milestones, tags |
| Diffusion | Repository browsing (Git, SVN, Mercurial) |
| Differential | Pre-commit code review |
| Herald | Rules-based automation (notifications, assignments) |
| Dashboard | Custom landing pages with panels |
| Audit | Post-commit review |
| Calendar | Events and availability |

## Troubleshooting

- **"MySQL credentials not configured"** — Check `local.json` has correct mysql.host/user/pass. Remember `%` doesn't match `localhost` in MySQL grants.
- **"Account needs approval"** — Set `auth.require-approval` to `false` or use `bin/auth recover`.
- **Setup issues in UI** — Check the notification badge after login; common ones are `local_infile`, `sql_mode`, missing pygments.
- **Blank page or 502** — Check `php_fpm` is running and Apache can reach the socket (`proxy:unix:/var/run/php-fpm.sock`).
- **"HTTPS" issues** — Ensure `SetEnv HTTPS on` is set in the Apache VirtualHost when behind a TLS proxy.
