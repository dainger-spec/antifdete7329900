# Письма Lumen — шаблоны

Фирменные шаблоны всех писем сервера аккаунтов (`lumen-api-server`, `internal/mail/templates.go`). На каждое письмо, на русском и английском, — HTML и текстовая версия. Формат согласован с серверным агентом и записан у него: `docs/SITE_API.md` §11. Посмотреть, как письма приходят: `prototype/email/index.html` (раздел «Письма сервера» на странице обзора прототипа).

## Что здесь

| Путь | Что |
|---|---|
| `templates/<name>.<lang>.html` | HTML-версия, Go `html/template` |
| `templates/<name>.<lang>.txt` | текстовая версия, Go `text/template`; первой строкой — тема: `{{define "subject"}}…{{end}}` |
| `templates/lumen-mark-1.png` | логотип: знак Lumen в плитке, PNG 144×144 (5 КБ), показывается 48×48; сервер вкладывает его в письмо |
| `src/build.mjs` | генератор: рамка и тексты всех писем в одном месте (знак для `templates/` берётся из `src/lumen-mark-1.png`) |
| `src/render.go` | собирает каждый шаблон движком сервера (Go 1.24, `html/template` и `text/template`) с образцом данных и пишет превью |
| `src/check.mjs` | правила, по которым проверяется каждый шаблон |

`<lang>` — `ru` или `en`. `<name>` — по одному на каждую функцию в `templates.go`:

| name | Функция в templates.go | Поля данных |
|---|---|---|
| `signup_code` | `SignupCode` | `Code` |
| `signup_existing` | `SignupExisting` | `SiteURL` |
| `password_reset_code` | `PasswordResetCode` | `Code` |
| `password_changed` | `PasswordChanged` | — (с `SiteURL` слова «сбросьте пароль» становятся ссылкой) |
| `invite` | `Invite` | `OwnerEmail`, `AcceptURL`, `Expires` |
| `seat_revoked` | `SeatRevoked` | — |
| `reminder` | `Reminder` | `PlanName`, `When`, `Ends`, `SiteURL` |
| `payment_received` | `PaymentReceived` | `Number`, `PlanName`, `Cycle`, `PriceUSD`, `Amount`, `Ticker`, `Ends` |
| `deletion_scheduled` | `DeletionScheduled` | `Due`, `SiteURL` |
| `deletion_cancelled` | `DeletionCancelled` | — |

Каждому HTML-шаблону нужен ещё `LogoURL` (ниже, «Логотип»).

## Как подключить

Пересобрать после правки: `node design/site/email/src/build.mjs`. Он пишет `templates/`, гоняет `render.go` и `check.mjs` и падает, если хоть один шаблон не собирается или нарушает правила. Тексты правятся в `src/build.mjs`, а не в `templates/` руками: иначе следующая сборка их перезапишет.

1. **Файлы.** Скопировать `templates/` целиком — 40 шаблонов и `lumen-mark-1.png` — в `internal/mail/templates/` и встроить их в бинарник:

   ```go
   //go:embed templates
   var files embed.FS
   ```

2. **Данные** — одна плоская структура; поля, не нужные письму, остаются пустыми:

   ```go
   type Data struct {
   	Code, SiteURL, OwnerEmail, AcceptURL, Expires, PlanName, When, Ends,
   	Number, Cycle, PriceUSD, Amount, Ticker, Due string
   	LogoURL htmltpl.URL // cid:lumen-mark-1, или пусто
   }
   ```

   Строки форматирует Go, как сейчас (`date`, `pick`), а шаблон только ставит их на место:
   - даты (`Expires`, `Ends`, `Due`): «29 ноября 2026, 09:00 UTC» / «29 November 2026, 09:00 UTC»;
   - `When`: «завтра» или «через 7 дней» / «tomorrow» или «in 7 days»;
   - `Cycle`: «месяц», «год» или «проверочный платёж, 1 день» / «one month», «one year» или «a check payment, one day».

   `SiteURL` — без слеша на конце; ссылки (`/login`, `/reset-password`, `/account`) шаблон собирает сам. `AcceptURL` — ссылка целиком, с кодом приглашения.

3. **Сборка письма.** Каждый файл — свой набор шаблонов, иначе имена `subject` столкнутся:

   ```go
   func render(name, locale string, d Data) (subject, text, html string, err error) {
   	lang := "ru"
   	if locale == "en" {
   		lang = "en"
   	}
   	base := "templates/" + name + "." + lang
   	t, err := texttpl.New(name + "." + lang + ".txt").Option("missingkey=error").ParseFS(files, base+".txt")
   	if err != nil {
   		return
   	}
   	var s, b, h bytes.Buffer
   	if err = t.ExecuteTemplate(&s, "subject", d); err != nil {
   		return
   	}
   	if err = t.Execute(&b, d); err != nil {
   		return
   	}
   	ht, err := htmltpl.ParseFS(files, base+".html")
   	if err != nil {
   		return
   	}
   	if err = ht.Execute(&h, d); err != nil {
   		return
   	}
   	return s.String(), b.String(), h.String(), nil
   }
   ```

   Шаблоны лучше разобрать один раз при старте, а не при каждом письме. `html/template` сам экранирует каждое значение по месту: почта владельца в тексте, ссылка в `href`.

4. **Отправка.**
   - В `Message` и в `mail_outbox` добавляется HTML-версия (колонка `html`).
   - **Resend:** в запросе `"html"` рядом с `"text"`, `"reply_to": ["support@lumenbrowser.io"]` и вложенный логотип.
   - **SMTP:** `multipart/alternative` — сначала `text/plain`, потом `multipart/related` с `text/html` и логотипом (`Content-ID: <lumen-mark-1>`), всё в UTF-8 — плюс заголовок `Reply-To`.
   - **FileSender** — то же, что SMTP, чтобы `.eml` открывался с HTML.

5. **Отправитель и ответы.** `From: Lumen <no-reply@mail.lumenbrowser.io>` (`LUMEN_MAIL_FROM`), `Reply-To: support@lumenbrowser.io` — например, новой настройкой `LUMEN_MAIL_REPLY_TO`. Человек отвечает в поддержку, а не в пустоту; об этом сказано в подвале каждого письма.

6. **Логотип** (`docs/SITE_API.md` §11). Сервер вкладывает `lumen-mark-1.png` в письмо (`Content-ID`) и передаёт `LogoURL` = `cid:lumen-mark-1` — типом `template.URL`: обычную строку с `cid:` `html/template` заменит на `#ZgotmplZ`. Если отправитель не умеет вложений, `LogoURL` пуст, и на месте знака стоит слово «Lumen» — светлым, как весь текст письма: тёмное слово на тёмной странице пропало бы. Шаблону всё равно, откуда картинка: если владелец решит, что логотип должен идти по ссылке, сервер передаст в `LogoURL` адрес `https://…` — и больше ничего менять не придётся.

## Что гарантируют шаблоны

Всё это проверяет `src/check.mjs` на каждой сборке. `src/render.go` собирает каждый файл движком сервера трижды: с образцом данных для превью, с логотипом `cid:lumen-mark-1` и без логотипа. Сборка падает, если в выводе есть `ZgotmplZ` или `<no value>`, если тема не в одну строку или если письмо тяжелее 100 КБ.

- **Вёрстка.** Только таблицы (`role="presentation"`), без flexbox и grid. Стили только построчные: без `<style>`, классов, медиазапросов, скриптов и комментариев. Одна колонка не шире 600 px: `width="600"` и `max-width:100%`, поэтому на телефоне колонка сжимается.
- **Цвета.** Заданы явно и только hex: Outlook не понимает `rgba()`. Фон стоит на `body`, на обёртке и на колонке, цвет — у каждого текста и каждой ссылки. Цвета сайта: фон `#060709`, поверхность `#161920`, текст `#ECEEF2` / `#A2A9B6` / `#8A93A3`, ссылки `#6F8FEA`, кнопка `#F4F5F8` с текстом `#0A0B0E`.
- **Тёмная тема.** Письмо и так тёмное. Почтовые программы с полной инверсией (Gmail на iPhone, классический Outlook) делают его светлым целиком: тёмного текста на тёмном фоне не бывает ни в одном режиме. `color-scheme: light dark` говорит Apple Mail, что письмо готово к обеим темам, и та его не трогает.
- **Логотип.** Единственная картинка в письме — то, что сервер передал в `LogoURL`, с `alt="Lumen"` и размерами. Если картинки не показаны, на её месте стоит «Lumen» шрифтом сайта; если её нет совсем — тоже слово «Lumen». Письмо читается целиком в любом случае.
- **Код** — крупным моноширинным шрифтом (34 px, разрядка 8 px) в отдельной рамке. При копировании разрядка не добавляет пробелов.
- **Без лишнего.** Нет баннеров, колонок, градиентов, картинок вместо текста, пикселей и отслеживающих ссылок. Извне письмо не грузит ничего. Ссылки ведут только на сайт (`SiteURL`) и в приглашение (`AcceptURL`).
- **Мелочи.** У каждого письма есть строка предпросмотра для списка входящих (скрыта в самом письме). Номера и даты не превращаются в ссылки на iPhone (`format-detection`). Типографика — та же, что на сайте: число держит слово, тире держит слово перед собой.
- **Вес** — около 7 КБ на письмо; Gmail обрезает письма тяжелее 102 КБ.

## Что изменилось в текстах

Тексты — серверные, из `templates.go`, разложены под вёрстку: строка, затем код, кнопка или детали, затем примечания вторым тоном. Две правки по существу:

1. «Если вы не создавали аккаунт, просто не отвечайте на это письмо» → «…ничего делать не нужно», и так же в сбросе пароля: теперь ответ на письмо приходит в поддержку.
2. В письме об удалении аккаунта к удаляемому добавлены «зашифрованные данные синхронизации на сервере» — так в `docs/SITE_API.md` §4.

Ещё в письме о смене пароля слова «сбросьте пароль» стали ссылкой, а «напишите в поддержку» дополнены словами «просто ответьте на это письмо».
