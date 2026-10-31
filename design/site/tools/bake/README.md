# Картинки сцен главной: чем они сделаны

Несколько сцен главной показывают готовые картинки, а не рисуют их в браузере: так легче и на телефоне, и на старом Mac. Здесь — скрипты, которыми эти картинки сделаны, как есть. Нужны Node 22 с Playwright и Python с Pillow и NumPy; сеть не нужна. Команды — из `design/site/`. Вступление с MacBook делается отдельно: `tools/hero/` (около 45 минут).

## Прогрев — страницы за рифлёным стеклом

`assets/scenes/warmup/<сайт>-{d,m}.webp` и `<сайт>-glow.webp`. Страницы — выдуманные шведские сайты (`warmup/pages/*.html`, ни одного настоящего бренда), «фотографии» на них нарисованы процедурно.

```bash
cd tools/bake/warmup
python3 -I photos.py img && python3 -I photos2.py img     # «фотографии» → img/
node render.mjs pages raw                                  # страницы → raw/*.png (1200 px ×4/3 и 390 px ×2)
python3 -I flute.py raw out 1.7 0.85                       # рифлёное стекло → out/*.webp
cp out/*.webp ../../../prototype/assets/scenes/warmup/
```

Число рёбер в `flute.py` (40 на компьютере, 12 на телефоне) должно совпадать с `--reeds` в `warmup.css`. `grain.png` — плитка шума 128 × 128.

## Цифры — макро дисплея

`assets/scenes/numbers/display.webp`: код продукта на дисплее, каждый пиксель — три субпикселя в синих цветах бренда, малая глубина резкости.

```bash
python3 -I tools/bake/numbers/macro.py prototype/assets/scenes/numbers/display.webp 2880 1600 6 0.78 1.75 82 22 -3
```

## Прокси — свет окна в тёмной комнате

`assets/scenes/proxy/glow.png` и `glow-phone.png`: размытый скруглённый прямоугольник, к краю картинки ровно в ноль, с дизерингом (без полос).

```bash
python3 -I tools/bake/proxy/glow.py prototype/assets/scenes/proxy
```

## Шифрование — замок для режима без движения

`assets/scenes/encryption/lock.png`: тот же замок из кода, что рисует `encryption.js`, снятый один раз, — для тех, у кого нет JavaScript.

```bash
node tools/preview-scene.mjs encryption
node tools/bake/encryption/lockpng.mjs prototype/_preview/encryption-ru.html prototype/assets/scenes/encryption/lock.png
rm -r prototype/_preview
```
