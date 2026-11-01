// Reads every mail template the way the Lumen server will — html/template for .html, text/template
// for .txt, each file a set of its own — runs it with sample data, and writes the previews: the
// HTML letter, the text letter with its subject, and a page listing them all. A template that does
// not parse, names a field the data has not got, or has no one-line subject stops the build.
//
//	go run design/site/email/src/render.go design/site/email design/site/prototype/email
package main

import (
	"bytes"
	"fmt"
	htmltpl "html/template"
	"os"
	"path/filepath"
	"sort"
	"strings"
	texttpl "text/template"
)

// Data is what the server passes every template (lumen-api-server, docs/SITE_API.md §11): one flat set
// of fields, the ones a letter does not use left empty. Dates and words like «завтра» / «через 7 дней» /
// «месяц» come formatted (internal/mail: date, pick), so the templates only place them. LogoURL is a
// template.URL — cid:lumen-mark-1 when the server puts the logo into the letter, empty when it can't (the
// mark is then the word «Lumen»); a plain string with cid: would come out as #ZgotmplZ.
type Data struct {
	Code, SiteURL, OwnerEmail, AcceptURL, Expires, PlanName, When, Ends, Number, Cycle, PriceUSD, Amount, Ticker, Due string
	LogoURL htmltpl.URL
}

var sample = map[string]Data{
	"ru": {
		Code: "482917", SiteURL: "https://lumenbrowser.io", LogoURL: "lumen-mark-1.png",
		OwnerEmail: "anna@example.com", AcceptURL: "https://lumenbrowser.io/team/accept?code=tq3v9x7k2m4p8r6w1y5z",
		Expires: "15 ноября 2026, 09:00 UTC", PlanName: "Команда", When: "через 7 дней", Ends: "29 ноября 2026, 09:00 UTC",
		Number: "LMN-000003", Cycle: "месяц", PriceUSD: "149.00", Amount: "149.000000", Ticker: "USDT", Due: "8 ноября 2026, 09:00 UTC",
	},
	"en": {
		Code: "482917", SiteURL: "https://lumenbrowser.io", LogoURL: "lumen-mark-1.png",
		OwnerEmail: "anna@example.com", AcceptURL: "https://lumenbrowser.io/team/accept?code=tq3v9x7k2m4p8r6w1y5z",
		Expires: "15 November 2026, 09:00 UTC", PlanName: "Team", When: "in 7 days", Ends: "29 November 2026, 09:00 UTC",
		Number: "LMN-000003", Cycle: "one month", PriceUSD: "149.00", Amount: "149.000000", Ticker: "USDT", Due: "8 November 2026, 09:00 UTC",
	},
}

// The order and the names the review page shows.
var order = []string{"signup_code", "signup_existing", "password_reset_code", "password_changed", "invite", "seat_revoked", "reminder", "payment_received", "deletion_scheduled", "deletion_cancelled"}
var titles = map[string]string{
	"signup_code": "Код подтверждения регистрации", "signup_existing": "Аккаунт с этим адресом уже есть",
	"password_reset_code": "Код сброса пароля", "password_changed": "Пароль изменён",
	"invite": "Приглашение в команду", "seat_revoked": "Место в команде закрыто",
	"reminder": "Напоминание о конце периода", "payment_received": "Квитанция об оплате",
	"deletion_scheduled": "Аккаунт будет удалён", "deletion_cancelled": "Удаление отменено",
}

func die(f string, a ...any) { fmt.Fprintf(os.Stderr, "MAIL: "+f+"\n", a...); os.Exit(1) }

func main() {
	if len(os.Args) != 3 {
		die("usage: render.go <email dir> <preview dir>")
	}
	src, dst := filepath.Join(os.Args[1], "templates"), os.Args[2]
	if err := os.MkdirAll(dst, 0o755); err != nil {
		die("%v", err)
	}
	files, _ := filepath.Glob(filepath.Join(src, "*.*.html"))
	sort.Strings(files)
	if len(files) != len(order)*2 {
		die("%d HTML templates, want %d", len(files), len(order)*2)
	}
	subjects := map[string]string{}
	for _, name := range order {
		for _, lang := range []string{"ru", "en"} {
			base := name + "." + lang
			d := sample[lang]
			// HTML, as the server will: html/template escapes every value for its place.
			h, err := htmltpl.ParseFiles(filepath.Join(src, base+".html"))
			if err != nil {
				die("%s.html: %v", base, err)
			}
			var hb bytes.Buffer
			if err := h.Execute(&hb, d); err != nil {
				die("%s.html: %v", base, err)
			}
			// As the server will send it: the logo inside the letter, then with no logo at all.
			for _, logo := range []htmltpl.URL{"cid:lumen-mark-1", ""} {
				v := d
				v.LogoURL = logo
				var vb bytes.Buffer
				if err := h.Execute(&vb, v); err != nil {
					die("%s.html with LogoURL %q: %v", base, logo, err)
				}
				out := vb.String()
				if strings.Contains(out, "ZgotmplZ") {
					die("%s.html with LogoURL %q: ZgotmplZ", base, logo)
				}
				if logo != "" && !strings.Contains(out, `src="cid:lumen-mark-1"`) {
					die("%s.html: the embedded logo did not land", base)
				}
				if logo == "" && (strings.Contains(out, "<img") || !strings.Contains(out, ">Lumen</span>")) {
					die("%s.html: with no logo, the mark must be the word «Lumen»", base)
				}
				if len(out) > 100*1024 {
					die("%s.html: %d bytes — over 100 KB", base, len(out))
				}
			}
			// password_changed without SiteURL (§11 lists no fields for it): the link falls back to words.
			if name == "password_changed" {
				v := d
				v.SiteURL = ""
				var vb bytes.Buffer
				if err := h.Execute(&vb, v); err != nil || strings.Contains(vb.String(), `href="/`) {
					die("%s.html: without SiteURL a link must not point at /…", base)
				}
			}
			// Text and subject: text/template, the subject a template of its own in the same file.
			t, err := texttpl.New(base + ".txt").Option("missingkey=error").ParseFiles(filepath.Join(src, base+".txt"))
			if err != nil {
				die("%s.txt: %v", base, err)
			}
			var sb, tb bytes.Buffer
			if err := t.ExecuteTemplate(&sb, "subject", d); err != nil {
				die("%s.txt: no subject: %v", base, err)
			}
			if err := t.Execute(&tb, d); err != nil {
				die("%s.txt: %v", base, err)
			}
			subject := sb.String()
			if subject == "" || strings.ContainsAny(subject, "\r\n") {
				die("%s.txt: the subject must be one line, not empty", base)
			}
			for _, out := range []string{hb.String(), tb.String(), subject} {
				if strings.Contains(out, "<no value>") || strings.Contains(out, "ZgotmplZ") {
					die("%s: a value did not land (<no value> or ZgotmplZ)", base)
				}
			}
			subjects[base] = subject
			if err := os.WriteFile(filepath.Join(dst, base+".html"), hb.Bytes(), 0o644); err != nil {
				die("%v", err)
			}
			txt := "Subject: " + subject + "\nFrom: Lumen <no-reply@mail.lumenbrowser.io>\nReply-To: support@lumenbrowser.io\n\n" + tb.String()
			if err := os.WriteFile(filepath.Join(dst, base+".txt"), []byte(txt), 0o644); err != nil {
				die("%v", err)
			}
		}
	}
	logo, err := os.ReadFile(filepath.Join(src, "lumen-mark-1.png"))
	if err != nil {
		die("%v", err)
	}
	if err := os.WriteFile(filepath.Join(dst, "lumen-mark-1.png"), logo, 0o644); err != nil {
		die("%v", err)
	}
	if err := os.WriteFile(filepath.Join(dst, "index.html"), []byte(gallery(subjects)), 0o644); err != nil {
		die("%v", err)
	}
	fmt.Printf("RENDERED %d letters with Go's html/template and text/template → %s\n", len(subjects)*2, dst)
}

// gallery is the review page: every letter as it arrives, Russian and English, with the subject
// and the text version a click away.
func gallery(subjects map[string]string) string {
	var b strings.Builder
	b.WriteString(`<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Письма Lumen — шаблоны</title>
<style>
  body { margin: 0; background: #060709; color: #ECEEF2; font: 400 15px/22px -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif; }
  .wrap { max-width: 1320px; margin: 0 auto; padding: 32px 16px 80px; }
  a { color: #6F8FEA; }
  h1 { font: 600 30px/36px -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif; margin: 12px 0 8px; }
  .lead { color: #A2A9B6; max-width: 760px; margin: 0; }
  .mail { margin-top: 48px; }
  .mail h2 { font: 600 18px/26px inherit; margin: 0; }
  .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 20px; margin-top: 12px; }
  .pane { border: 1px solid #1E222A; border-radius: 16px; overflow: hidden; background: #0B0C0F; }
  .head { display: flex; justify-content: space-between; gap: 12px; padding: 10px 14px; border-bottom: 1px solid #1E222A; font-size: 13px; color: #8A93A3; }
  .head b { color: #ECEEF2; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  iframe { display: block; width: 100%; height: 640px; border: 0; background: #060709; }
  @media (max-width: 899px) { .grid { grid-template-columns: minmax(0, 1fr); } }
</style>
</head>
<body><div class="wrap">
<a href="../index.html">← Все страницы</a>
<h1>Письма сервера</h1>
<p class="lead">Десять писем из internal/mail/templates.go сервера, на русском и английском, как их соберёт сервер: шаблоны прочитаны Go (html/template и text/template) и исполнены с образцом данных. У каждого письма — текстовая версия с темой. Отправитель — no-reply@mail.lumenbrowser.io, ответы — в support@lumenbrowser.io. Логотип сервер вкладывает в само письмо (docs/SITE_API.md §11): извне письмо не грузит ничего.</p>
`)
	for _, name := range order {
		fmt.Fprintf(&b, "<section class=\"mail\" id=\"%s\"><h2>%s</h2><div class=\"grid\">\n", name, titles[name])
		for _, lang := range []string{"ru", "en"} {
			base := name + "." + lang
			fmt.Fprintf(&b, "<div class=\"pane\"><div class=\"head\"><b>%s</b><span><a href=\"%s.html\">HTML</a> · <a href=\"%s.txt\">текст</a></span></div><iframe src=\"%s.html\" title=\"%s\" loading=\"lazy\"></iframe></div>\n",
				htmltpl.HTMLEscapeString(subjects[base]), base, base, base, htmltpl.HTMLEscapeString(subjects[base]))
		}
		b.WriteString("</div></section>\n")
	}
	b.WriteString("</div></body>\n</html>\n")
	return b.String()
}
