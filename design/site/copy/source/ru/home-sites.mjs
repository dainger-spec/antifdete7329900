// Сцена «Страны»: сайт видит страну, язык и время профиля.
export default {
  title: 'Подлинность',
  overlay: ['Страница рисуется настоящим WebKit.', 'Ровно так, как в Safari.'],
  head: ['Один Mac — много Safari.', 'У каждой своя страна.'],
  sees: 'Сайт видит',
  profiles: [
    { name: 'Магазин', code: 'DE', country: 'Германия', lang: 'de-DE', site: 'shop.example', c1: '#FF9A62', c2: '#E2466E' },
    { name: 'Реклама', code: 'US', country: 'США', lang: 'en-US', site: 'ads.example', c1: '#5E8DFF', c2: '#8C5CFF' },
    { name: 'Тесты', code: 'JP', country: 'Япония', lang: 'ja-JP', site: 'app.example', c1: '#FF5D8F', c2: '#FFB5CB' },
  ],
};
