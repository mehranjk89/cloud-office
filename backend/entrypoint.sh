
#!/usr/bin/env sh
set -eu

# بررسی آماده بودن سرویس‌های دیتابیس و Redis پیش از اجرای جنگو
python - <<'PY'
import os
import socket
import time

checks = []

if os.getenv('USE_POSTGRES', '').lower() in {'1', 'true', 'yes', 'on'}:
    checks.append(('DATABASE_HOST', int(os.getenv('DATABASE_PORT', '5432'))))

if os.getenv('REDIS_URL', '').startswith('redis://'):
    from urllib.parse import urlparse
    parsed = urlparse(os.environ['REDIS_URL'])
    checks.append((parsed.hostname or 'redis', parsed.port or 6379))

for host_env, port in checks:
    host = os.getenv(host_env, host_env)

    for attempt in range(30):
        try:
            with socket.create_connection((host, port), timeout=2):
                break
        except OSError:
            if attempt == 29:
                raise
            time.sleep(2)
PY

# اجرای مهاجرت‌های دیتابیس
python manage.py migrate --noinput

# آماده‌سازی فایل‌های استاتیک
python manage.py collectstatic --noinput

# ایجاد ادمین یا بازنشانی رمز او در صورت فعال بودن تنظیمات
if [ "${CREATE_SUPERUSER:-0}" = "1" ]; then
  python manage.py shell <<'PY'
import os
from django.contrib.auth import get_user_model

User = get_user_model()

username = os.environ.get('DJANGO_SUPERUSER_USERNAME', 'admin')
email = os.environ.get('DJANGO_SUPERUSER_EMAIL', 'admin@example.com')
password = os.environ.get('DJANGO_SUPERUSER_PASSWORD')

if not password:
    print(
        'WARNING: CREATE_SUPERUSER=1 but '
        'DJANGO_SUPERUSER_PASSWORD is empty; no admin created.'
    )
else:
    user = User.objects.filter(username=username).first()

    if user is None:
        User.objects.create_superuser(
            username=username,
            email=email,
            password=password,
        )
        print(f"Superuser {username!r} created.")

    elif os.environ.get('RESET_SUPERUSER_PASSWORD', '0') == '1':
        user.email = email
        user.is_staff = True
        user.is_superuser = True
        user.set_password(password)
        user.save(
            update_fields=[
                'email',
                'is_staff',
                'is_superuser',
                'password',
            ]
        )
        print(f"Superuser {username!r} password reset.")
    else:
        print(
            f"Superuser {username!r} already exists; "
            'password was not changed.'
        )
PY
fi

# اجرای سرور Django از طریق Daphne
exec daphne -b 0.0.0.0 -p 8000 config.asgi:application
