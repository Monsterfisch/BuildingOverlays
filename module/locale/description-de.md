# Building Overlays

**Autor**: Monsterfish
**Version**: 1.0.0

Zeichnet zusätzliche Grafiken über Gebäude. Das Spiel macht dies selbst für Turmzinnen: ein Bild, das den Wehrgang verdeckt, sodass Einheiten nicht vor dem Turm zu stehen scheinen, und das verschwindet, sobald Einheiten darauf stehen. Mit diesem Modul lassen sich solche Grafiken für weitere Gebäude hinzufügen oder ändern, indem man einfach PNG-Dateien in den Ordner `overlays` legt.

## Großes Torhaus

Ein leeres großes Torhaus erhält ein Bild über seinen Türmen (je eines für Ausrichtung nach links unten und nach rechts unten). Sobald Truppen das Torhaus betreten, verschwindet das Bild. In den Einstellungen abschaltbar.

## Bergfried-Eingang

Behebt einen Grafikfehler des Spiels: Bei Bergfrieden in zwei der vier Ausrichtungen wurde die Mitte des Eingangs im falschen Licht gezeichnet – ein heller Pfeiler zwischen schattigen Türmen oder ein dunkler in einem hellen Torbogen. Nun passt sie zu den Türmen daneben. In den Einstellungen abschaltbar.

## Truppen auf dem Gebäude

Ein Overlay verschwindet, solange eine Einheit auf dem Gebäude steht – außer dem Lord, der immer auf seinem Bergfried steht und dessen Overlay sonst dauerhaft ausblenden würde. Ist „Overlays nur ausblenden, während der Mauszeiger auf dem Gebäude liegt“ aktiviert, behalten Türme, Torhäuser und Bergfriede ihre Zinnen unabhängig von der Belegung und blenden sie nur bei Mauskontakt aus. Das betrifft die Overlays dieses Moduls und die Turmdächer des Spiels; Turmzinnen und alle übrigen Spiel-Overlays behalten ihre eigenen Regeln. Ein Overlay mit `units = "any"` wird immer gezeichnet (etwa für Zinnen vor Truppen).

## Gebäude davor verdecken Overlays

Das Spiel zeichnet Overlays in einem Stück an der vorderen Ecke eines Gebäudes, sodass sie durch benachbarte Türme und Mauern hindurchscheinen. Dieses Modul zeichnet eigene und spielinterne Overlays stattdessen in schmalen Streifen zusammen mit den Gebäudefeldern, sodass alles davor sie korrekt verdeckt. Überstehende Teile folgen dem hintersten Feld. In den Einstellungen abschaltbar („Gebäude davor verdecken die Overlays“).

## Overlays im Spiel verschieben

Wähle ein beliebiges Gebäude. Sein Fenster listet links seine Overlays auf: die dieses Moduls sowie die eigenen Grafiken des Spiels als „Game #n“ (auch diese lassen sich verschieben; wann sie erscheinen, bleibt Sache des Spiels). Ein Klick wählt ein Overlay aus – es erscheint mit magentafarbenem Rahmen, und rechts im Fenster erscheinen blaue Pfeiltasten. Jeder Klick verschiebt um die Schrittweite („Step“ wechselt zwischen 1, 5 und 20 Pixeln); erneutes Anklicken beendet die Auswahl. „Save“ speichert die Positionen im `ucp`-Ordner des Spiels, und das Modul verwendet sie ab dann. Das Werkzeug ist in den Einstellungen abschaltbar.

## Grafiken hinzufügen oder ändern

Lege eine PNG-Datei in den Ordner `overlays` (transparente Bereiche bleiben transparent) und beschreibe sie in `overlay_list.lua`: Gebäude, Eingangsrichtung, Truppenbelegung und Position.

## Nutzung durch ein Plugin

Ein Plugin kann eigene Overlays mitbringen. Lege die PNGs und eine `overlays.lua` in `resources/modsupport/building-overlays/` des Plugins und rufe in dessen `enable` auf:

    local overlays = modules["building-overlays"]
    if overlays ~= nil then
      overlays:registerOverlaySource("ucp/plugins/MyPlugin-*/resources/modsupport/building-overlays/")
    end

Ein gleichnamiges Overlay ersetzt das des Moduls. Die Schaltfläche „Save“ schreibt auch die Positionen dieses Plugins in den `ucp`-Ordner; die eigene `overlays.lua` des Plugins bleibt unverändert.

Dieselbe Datei kann auch die eigenen Grafiken des Spiels verschieben, die im Fenster als „Game #n“ aufgeführt werden.
