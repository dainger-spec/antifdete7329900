# Вопрос 4. Формальности Apple

Все цитаты ниже — **из документации**. Страницы developer.apple.com скачаны 7 ноября 2026 года, и цитаты сверены с их текстом; правила App Review имеют пометку «Last Updated: October 16, 2026». Страницы support.apple.com, apple.com, webkit.org и telegram.org из этой сессии не открылись: сеть их не пропускает. Сведения с этих сайтов помечены как **не сверено**.

## Учётная запись разработчика

| | Цитата | Источник |
|---|---|---|
| Цена | «The Apple Developer Program is 99 USD per membership year, or in local currency where available.» | https://developer.apple.com/programs/whats-included/ |
| Частное лицо | «Your name will be displayed as the seller name of your apps on the App Store.» | https://developer.apple.com/programs/enroll/ |
| Индивидуальный предприниматель | «If you're an individual or sole proprietor/single-person business, your personal legal name will be listed as the seller on the App Store.» | https://developer.apple.com/help/account/membership/program-enrollment/ |
| Организация | «We do not accept DBAs, fictitious business names, trade names, or branches. Your organization's name will be displayed as the seller name…» | https://developer.apple.com/programs/enroll/ |
| D-U-N-S | «Your organization (excluding government entities) must have a D-U-N-S Number so that we can verify your organization's identity, legal entity status, and address.» | https://developer.apple.com/programs/enroll/ ; https://developer.apple.com/help/account/membership/D-U-N-S/ |
| Сайт | «Your organization's website must be publicly available and functional, and its domain name must be associated with your organization.» | https://developer.apple.com/programs/enroll/ |
| Санкции | «Enrollment may not be supported in certain regions, for example due to sanctions or other restrictions.» | https://developer.apple.com/help/account/membership/program-enrollment/ |
| ЕС (DSA) | «Apple will publish this information on your App Store product page when your app is distributed in any of the 27 territories of the EU. Even if you don't distribute apps in the EU, you'll still need to declare a trader status.» | https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/ |

Что это значит для нас:

- **Организация.** Нужны юридическое лицо, D-U-N-S, сайт на домене компании и доля в App Store: 30%, или 15% по Small Business Program (та же страница whats-included). Продавцом в App Store будет значиться компания.
- **Частное лицо.** Продавцом значится имя и фамилия человека, так сделан ExitAnty («Georgy Falin»).
- **Пункт 5.4 правил.** Если приложение когда-нибудь будет предлагать VPN, понадобится именно организация. Цитата приведена ниже.
- **Россия.** По Apple нашлись только оговорка о санкциях и, **не сверено**, страница поддержки https://support.apple.com/en-us/126891. Судя по выдержке поисковика, на ней сказано: «As of April 1, 2026, payment processing is no longer available on the App Store in Russia». Если владелец или юрлицо в России, этот вопрос надо выяснить до регистрации. Это риск №1 списка формальностей.

## Возрастная отметка и категория

- Возраст: **16+**, это самый низкий допустимый для браузера. В таблице для iOS 26 и новее строка 16+ содержит «Capabilities: Unrestricted web access». На версиях ниже 26 встроенный браузер давал 17+: «Unrestricted web access, such as with an embedded browser». Определение: «Unrestricted Web Access: Users can navigate to any webpage within the app or freely browse the web. May include: embedded browser functionality or browser app.» Источник: https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions
- Новые вопросы анкеты (геолокация, знакомства) появятся с 16 ноября 2026 года, и ответить на них нужно до 12 января 2027 года: https://developer.apple.com/news/?id=yxkh08us
- Категория — **Utilities**: «Apps that enable the user to solve a problem or complete a specific task. For example: … web browsing…». Ни одна категория браузеры не запрещает. Предупреждение из правил: «Choosing categories that are not appropriate for your app is against the App Review Guidelines.» Источник: https://developer.apple.com/app-store/categories/

## Правила App Review, которые касаются такого приложения

Источник всех пунктов: https://developer.apple.com/app-store/review/guidelines/ (якорь `#<номер>`). Отдельного пункта про антидетект, мультиаккаунтинг или отпечатки в правилах нет. Ниже — самые близкие.

| Пункт | Текст (цитата) | Что значит для нас |
|---|---|---|
| [1.1.6](https://developer.apple.com/app-store/review/guidelines/#1.1.6) | «False information and features, including inaccurate device data or trick/joke functionality, such as fake location trackers.» | Подмена данных устройства — самый прямой риск отказа. Описание приложения не должно обещать «подмену устройства». |
| [2.5.1](https://developer.apple.com/app-store/review/guidelines/#2.5.1) | «Apps may only use public APIs … Apps should use APIs and frameworks for their intended purposes…» | Никакого приватного SPI WebKit, на котором стоит часть macOS-версии (`_setEnabled:forFeature:`, хуки инициализатора и т. п.). Остаются только публичные `proxyConfigurations`, `WKUserScript`, `WKContentRuleList`. |
| [2.5.6](https://developer.apple.com/app-store/review/guidelines/#2.5.6) | «Apps that browse the web must use the appropriate WebKit framework and WebKit JavaScript.» | WKWebView подходит. |
| 2.5.19 | «Don't include any hidden, dormant, or undocumented features…» | Все режимы должны быть видны рецензенту и описаны в Notes for Review (2.3.1). |
| [3.1.1](https://developer.apple.com/app-store/review/guidelines/#3.1.1) | «If you want to unlock features or functionality within your app … you must use in-app purchase. Apps may not use their own mechanisms to unlock content or functionality, such as license keys…» | **Нынешний лицензионный сервер в iOS-приложении напрямую не годится.** |
| [3.1.3(b)](https://developer.apple.com/app-store/review/guidelines/#3.1.3b) | «Apps that operate across multiple platforms may allow users to access … features they have acquired in your app on other platforms or your web site … provided those items are also available as in-app purchases within the app.» | Лицензию с сайта принять можно, только если то же самое продаётся и через IAP. |
| [3.1.3](https://developer.apple.com/app-store/review/guidelines/#3.1.3) | «Apps in this section cannot, within the app, encourage users to use a purchasing method other than in-app purchase, except for apps on the United States storefront…» | Ссылка на оплату на сайте разрешена только в витрине США. |
| [3.2.2(vii)](https://developer.apple.com/app-store/review/guidelines/#3.2.2) | «Artificially manipulating a user's visibility, status, or rank on other services unless permitted by that service's Terms and Conditions.» | Сценарии «накрутки» в мини-приложениях Telegram подпадают сюда. |
| [4.7](https://developer.apple.com/app-store/review/guidelines/#4.7) | «Apps may offer certain software that is not embedded in the binary, specifically HTML5 and JavaScript mini apps…» плюс 4.7.1–4.7.5: фильтр и жалобы на контент, никаких нативных API без разрешения, индекс ПО, возрастные ограничения | Применимо, если показывать каталог мини-приложений как свой. Веб-страница внутри браузера сюда не относится. |
| [5.2.1](https://developer.apple.com/app-store/review/guidelines/#5.2.1) / 4.1(c) | товарные знаки третьих лиц | «Telegram» нельзя ставить в название и иконку. |
| [5.2.2](https://developer.apple.com/app-store/review/guidelines/#5.2.2) | «If your app uses, accesses … or displays content from a third-party service, ensure that you are specifically permitted to do so under the service's terms of use. Authorization must be provided upon request.» | Telegram-режим: Apple вправе спросить разрешение Telegram. |
| [5.4](https://developer.apple.com/app-store/review/guidelines/#5.4) | «Apps offering VPN services must utilize the NEVPNManager API and may only be offered by developers enrolled as an organization.» | Прокси в WKWebView — не VPN-сервис, но слово «VPN» в описании приложения сразу включает этот пункт. |
| [5.6](https://developer.apple.com/app-store/review/guidelines/#5.6) | «Repeated manipulative or misleading behavior or other fraudulent conduct will lead to your removal…» | Риск для всей учётной записи, а не для одного приложения. |

## Документация API (взято из документации, доступность)

- `WKWebsiteDataStore.proxyConfigurations` — iOS 17.0, macOS 14.0: https://developer.apple.com/documentation/webkit/wkwebsitedatastore/proxyconfigurations-cdc1
- `ProxyConfiguration` (HTTP CONNECT, SOCKSv5, Relay, Oblivious HTTP) — iOS 17.0: https://developer.apple.com/documentation/network/proxyconfiguration
- `WKWebsiteDataStore(forIdentifier:)` — iOS 17.0, «Use this method to get a data store for a profile»: https://developer.apple.com/documentation/webkit/wkwebsitedatastore/init(foridentifier:)
- `limitsNavigationsToAppBoundDomains` — iOS 14.0: https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/limitsnavigationstoappbounddomains

## Telegram (не сверено: core.telegram.org и telegram.org отсюда недоступны)

- API Terms of Service: https://core.telegram.org/api/terms. Судя по выдержкам: своё api_id, слово «Unofficial» перед «Telegram» в названии, без официального логотипа.
- https://core.telegram.org/api/obtaining_api_id. Выдержка: «If you use the Telegram API for flooding, spamming, faking subscriber and view counters of channels, you will be banned forever.»
- Проверка initData мини-приложения (HMAC-SHA-256 от токена бота): https://core.telegram.org/bots/webapps
