# barberflow-deploy

Render build uchun ochiq "shim" repo. Bu yerda ilova kodi yo'q.

Haqiqiy kod private repo'da: `abdulroufjon726-create/barberflow-app`.

Render private repo'ni clone qila olmagani uchun, `build.sh` shu repo'da turadi
va build paytida private repo'ni **read-only deploy key** bilan clone qiladi.
Kalit Render'ning `DEPLOY_KEY_B64` env var'ida saqlanadi (repo'da sir yo'q).

- Build: `./build.sh` (clone + pip install + collectstatic)
- Start: `cd app/backend && python manage.py migrate --noinput && python manage.py seed_demo && daphne -b 0.0.0.0 -p $PORT config.asgi:application`

Baza ishlari start'da bajariladi, shunda ma'lumot bazasi (telefondagi tunnel)
vaqtincha uzilsa ham build muvaffaqiyatli tugaydi.
