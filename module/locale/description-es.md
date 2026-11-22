# Building Overlays

**Autor**: Monsterfish
**Versión**: 1.0.0

Dibuja imágenes adicionales sobre los edificios. El juego ya hace esto con las almenas de las torres: una imagen cubre la pasarela para que las unidades no parezcan fuera de la torre y desaparece cuando hay unidades encima. Este módulo permite añadir o cambiar imágenes así para otros edificios con solo poner archivos PNG en su carpeta `overlays`.

## Puerta grande

Una puerta grande vacía recibe una imagen sobre sus torres (una para entradas orientadas abajo a la izquierda y otra abajo a la derecha). Al subir tropas desaparece. Puede desactivarse en los ajustes.

## Entrada de la fortaleza

Corrige un error gráfico del juego: en dos de las cuatro orientaciones de la fortaleza, el centro de la entrada tenía la iluminación equivocada (pilar claro entre torres en sombra o pilar oscuro en arco claro). Ahora coincide con las torres laterales. Desactivable en ajustes.

## Tropas sobre el edificio

La superposición desaparece mientras haya una unidad en el edificio —salvo el señor, que siempre está en su fortaleza. Con «Ocultar superposiciones solo mientras el ratón esté sobre el edificio» activado, torres, puertas y fortalezas mantienen sus almenas con tropas encima y solo las ocultan al apuntar con el ratón (cubre este módulo y los techos de torres del juego). Una superposición con `units = "any"` se dibuja siempre.

## Los edificios delante cubren las superposiciones

El juego dibuja las superposiciones de una pieza en la esquina frontal, atravesando torres y muros contiguos. Este módulo dibuja sus imágenes y las del juego en tiras estrechas junto a las casillas del edificio, para que lo situado delante las cubra bien. Desactivable en ajustes.

## Mover superposiciones en el juego

Selecciona cualquier edificio: su panel lista a la izquierda sus superposiciones (las del módulo y las del juego como «Game #n»). Haz clic en una para seleccionarla con marco magenta y moverla con las flechas azules a la derecha («Step» alterna 1, 5 y 20 píxeles); vuelve a hacer clic para parar. «Save» escribe la posición de cada superposición en un archivo dentro de la carpeta `ucp` del juego, y el módulo usa esas posiciones a partir de entonces; el archivo tiene el formato del `overlays.lua` de un plugin. Desactivable en ajustes.

## Añadir o cambiar una imagen

Pon un PNG en `overlays` (las transparencias se conservan) y descríbelo en `overlay_list.lua`: edificio, orientación de la entrada, presencia de tropas y posición.

## Uso desde un plugin

Un plugin puede incluir sus propias superposiciones poniendo los PNG y un `overlays.lua` en `resources/modsupport/building-overlays/` del plugin y llamando en su `enable`:

    local overlays = modules["building-overlays"]
    if overlays ~= nil then
      overlays:registerOverlaySource("ucp/plugins/MyPlugin-*/resources/modsupport/building-overlays/")
    end

Una superposición con el mismo nombre sustituye a la del módulo. El botón Save también escribe las posiciones de ese plugin en la carpeta `ucp`; el propio `overlays.lua` del plugin permanece tal cual.

El mismo archivo también puede mover las imágenes propias del juego, las que el panel lista como «Game #n».
