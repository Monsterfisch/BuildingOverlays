# Building Overlays

**Auteur** : Monsterfish
**Version** : 1.0.0

Dessine des images supplémentaires par-dessus les bâtiments. Le jeu le fait lui-même pour les créneaux des tours : une image couvre le chemin de ronde afin que les unités ne semblent pas flotter dehors, et disparaît lorsqu'il y a des unités dessus. Ce module permet d'ajouter ou de modifier de tels calques pour d'autres bâtiments en déposant simplement des fichiers PNG dans son dossier `overlays`.

## Grande porte

Une grande porte vide reçoit une image sur ses tours (une pour l'entrée orientée en bas à gauche, une pour en bas à droite). Dès que des troupes montent sur la porte, l'image disparaît. Désactivable dans les paramètres.

## Entrée du donjon

Corrige un bug graphique du jeu : sur les donjons orientés dans deux sens sur quatre, le milieu de l'entrée était dessiné avec un mauvais éclairage (pilier clair entre tours ombragées ou pilier sombre dans une arche claire). Il s'accorde désormais avec les tours voisines. Désactivable dans les paramètres.

## Troupes sur le bâtiment

Un calque disparaît tant qu'une unité se trouve sur le bâtiment — sauf le seigneur, qui reste toujours sur son donjon et masquerait sinon son calque en permanence. Avec « Ne masquer les calques que lorsque la souris survole le bâtiment » activé, les tours, portes et donjons gardent leurs créneaux dessinés quels que soient leurs occupants et ne les masquent qu'au survol de la souris (cela couvre les calques de ce module et les toits de tours du jeu ; les créneaux natifs et autres calques conservent leurs règles). Un calque avec `units = "any"` est toujours dessiné.

## Les bâtiments devant masquent les calques

Le jeu dessine les calques d'un bloc à l'angle avant du bâtiment, les faisant transparaître à travers les tours et murs adjacents. Ce module dessine ses images et les calques natifs du jeu en fines bandes avec les cases du bâtiment, afin que tout ce qui est devant les masque correctement. Les parties qui dépassent suivent la case la plus en arrière. Désactivable dans les paramètres (« Laisser les bâtiments devant masquer les calques »).

## Déplacer les calques en jeu

Sélectionnez un bâtiment : son panneau liste à gauche ses calques (ceux du module et ceux du jeu en tant que « Game #n »). Cliquez sur l'un d'eux pour le sélectionner avec un cadre magenta et faire apparaître des flèches bleues à droite. Chaque clic déplace l'image selon le pas (« Step » alterne entre 1, 5 et 20 pixels) ; recliquez pour arrêter. « Save » enregistre sous `ucp/building-overlays-*`. La calibration valide la plus récente prévaut sur les valeurs par défaut du pack. Désactivable dans les paramètres.

## Ajouter ou modifier une image

Placez un PNG dans le dossier `overlays` (les zones transparentes restent transparentes) et décrivez-le dans `overlay_list.lua` : bâtiment, orientation de l'entrée, présence de troupes et position.

## Utilisation depuis un plugin

Un plugin peut fournir ses propres calques. Placez les PNG et un fichier `overlays.lua` dans `resources/modsupport/building-overlays/` du plugin et appelez dans son `enable` :

    local overlays = modules["building-overlays"]
    if overlays ~= nil then
      overlays:registerOverlaySource("ucp/plugins/MyPlugin-*/resources/modsupport/building-overlays/")
    end

Un calque portant le même nom que celui du module le remplace. Le bouton Save enregistre localement la calibration du plugin tout en conservant le fichier `overlays.lua` d'origine.

Le même fichier peut aussi déplacer les images propres au jeu, celles que le panneau liste en tant que « Game #n ».
