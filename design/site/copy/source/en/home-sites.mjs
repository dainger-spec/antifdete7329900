// Home scene "sites": the same site in three profiles — for each it is in the local language, with the local
// date and time. Beside it (under the window on a phone): what the site sees — country, language, time zone.
// The site's own text in the window is sample data (German, English, Japanese); it lives in the scene's
// template and is not translated.
export default {
  title: 'Countries',
  head: ['Every profile,', 'its own country.'],
  lead: 'Each profile takes its language and time zone from its proxy’s country — so sites open in the local language, on local time.',
  sees: 'What the site sees',
  label: 'A Safari window with the same news site in three profiles: for “Store” it is in German and shows Berlin time, for “Ads” in English with New York time, for “QA” in Japanese with Tokyo time.',
  profiles: [
    { name: 'Store', code: 'DE', country: 'Germany', lang: 'de-DE', zone: 'Europe/Berlin', time: '14:32' },
    { name: 'Ads', code: 'US', country: 'USA', lang: 'en-US', zone: 'America/New_York', time: '9:32 AM' },
    { name: 'QA', code: 'JP', country: 'Japan', lang: 'ja-JP', zone: 'Asia/Tokyo', time: '22:32' },
  ],
};
