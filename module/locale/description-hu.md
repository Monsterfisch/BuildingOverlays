# Building Overlays

**Szerző**: Monsterfish
**Verzió**: 1.0.0

További fedőképeket rajzol az épületek fölé. Maga a játék is így rajzolja a tornyok pártázatát: egy kép eltakarja a gyilokjárót, hogy az egységek ne tűnjenek a tornyon kívül állónak, és eltűnik, amikor katonák állnak rajta. Ez a modul lehetővé teszi hasonló képek hozzáadását és cseréjét más épületekhez is, egyszerűen PNG fájlok elhelyezésével az `overlays` mappában.

## Nagy kapuház

Az üres nagy kapuház fedőképet kap a tornyaira (külön képet a balra lefelé és jobbra lefelé néző bejárathoz). Ha csapatok lépnek a kapuházra, a kép eltűnik. Kikapcsolható a beállításokban.

## Vártorony bejárata

Javít egy játékon belüli grafikai hibát: négyből két elforgatásnál a bejárat közepe rossz megvilágítással jelent meg (világos pillér árnyékos tornyok közt, vagy sötét pillér világos boltívben). Mostantól illeszkedik a mellette lévő tornyokhoz. Kikapcsolható a beállításokban.

## Csapatok az épületen

A fedőkép eltűnik, amíg bármilyen egység áll az épületen — kivéve a lordot, aki mindig a vártornyán áll. A „Fedőképek elrejtése csak ha az egér az épület fölött van” beállítással a tornyok, kapuházak és vártornyok pártázata egységekkel is látszik, és csak az egér fölé húzásakor tűnik el (a modul fedőképeire és a toronytetőkre érvényes). A `units = "any"` fedőképek mindig látszanak.

## Az elöl álló épületek takarják a fedőképeket

A játék egy darabban rajzolja a fedőképeket az épület elülső sarkánál, így átlátszanak a szomszédos tornyokon és falakon. Ez a modul keskeny csíkokban, az épület mezőivel együtt rajzolja saját és a játék eredeti fedőképeit, így minden elöl álló elem helyesen takarja őket. Kikapcsolható a beállításokban.

## Fedőképek mozgatása játék közben

Válassz ki egy épületet: panelje bal oldalán láthatók a fedőképei (a moduléi és a játék „Game #n” képei). Kattints egyre a lila keretes kijelöléshez, majd a jobb oldali kék nyilakkal igazítsd („Step” 1, 5 és 20 pixel között vált). Újbóli kattintással állítsd le. A „Save” a `ucp/building-overlays-*` alá menti a kalibrációt; a legfrissebb érvényes kalibráció felülírja a csomag alapértékeit. Kikapcsolható a beállításokban.

## Kép hozzáadása vagy módosítása

Tegyél egy PNG-t az `overlays` mappába (az átlátszó részek átlátszók maradnak), és add meg az `overlay_list.lua` fájlban: melyik épület, milyen bejárati irány, állnak-e rajta csapatok, és hol helyezkedjen el.

## Használat pluginból

Egy plugin saját fedőképeket is hozhat. Tedd a PNG-ket és az `overlays.lua` fájlt a plugin `resources/modsupport/building-overlays/` mappájába, majd az `enable` függvényben hívd meg:

    local overlays = modules["building-overlays"]
    if overlays ~= nil then
      overlays:registerOverlaySource("ucp/plugins/MyPlugin-*/resources/modsupport/building-overlays/")
    end

Az azonos nevű fedőkép lecseréli a modul sajátját. A Save gomb helyben menti a plugin kalibrációját, az eredeti `overlays.lua` érintetlen marad.
