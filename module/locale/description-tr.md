# Building Overlays

**Yazar**: Monsterfish
**Sürüm**: 1.1.2

Binaların üzerine ek görseller çizer. Oyun bunu kule mazgalları için kendisi yapar: bir görsel geçidi örterek birimlerin kulenin dışında duruyormuş gibi görünmesini engeller ve üzerinde birim varken kaybolur. Bu modül `overlays` klasörüne PNG dosyaları bırakarak başka binalar için de benzer görseller eklemenizi ve değiştirmenizi sağlar.

## Büyük kapı binası

Boş bir büyük kapı binasının kuleleri üzerine bir görsel çizilir (girişi sol alta ve sağ alta bakanlar için ayrı). Birlikler kapı binasına çıkınca görsel kaybolur. Ayarlardan kapatılabilir.

## İç kale girişi

Oyundaki bir görsel hatasını düzeltir: dört yönden ikisine dönük iç kalelerde girişin ortası yanlış ışıkta çiziliyordu (gölgeli kuleler arasında parlak sütun veya parlak kemerde koyu sütun). Artık yanındaki kulelerle uyumludur. Ayarlardan kapatılabilir.

## Binadaki birlikler

Üzerinde herhangi bir birim dururken katman kaybolur — her zaman iç kalesinde duran lord hariç. «Katmanları yalnızca fare binanın üzerindeyken gizle» açıkken kuleler, kapı binaları ve iç kaleler üzerinde kim olursa olsun mazgallarını çizili tutar ve yalnızca fare üzerine geldiğinde gizler (bu modülün katmanlarını ve oyun kulelerinin çatılarını kapsar). `units = "any"` katmanları her zaman çizilir.

## Öndeki binalar katmanları örter

Oyun katmanları binanın ön köşesinde tek parça çizdiğinden yanındaki kule ve surların içinden görünürler. Bu modül hem kendi görsellerini hem oyunun katmanlarını binanın kareleriyle dar şeritler hâlinde çizer, böylece öndeki her şey onları doğru şekilde örter. Ayarlardan kapatılabilir.

## Katmanları oyun içinde taşıma

Herhangi bir binayı seçin; panelin solunda katmanları (modülün ve oyunun «Game #n» görselleri) listelenir. Birine tıklayıp eflatun çerçeveyle seçin ve sağdaki mavi oklarla taşıyın («Step» 1, 5 ve 20 piksel arasında geçer). Durdurmak için tekrar tıklayın. «Save» konumları oyunun `ucp` klasörüne kaydeder ve modül bundan sonra onları kullanır. Ayarlardan kapatılabilir.

## Görsel ekleme veya değiştirme

`overlays` klasörüne bir PNG koyun (saydam alanlar saydam kalır) ve `overlay_list.lua` içinde bina, giriş yönü, birlik durumu ve konumu tanımlayın.

## Bir eklentiden kullanma

Bir eklenti kendi katmanlarını getirebilir. PNG'leri ve `overlays.lua` dosyasını eklentinin `resources/modsupport/building-overlays/` klasörüne koyun ve `enable` içinde şunu çağırın:

    local overlays = modules["building-overlays"]
    if overlays ~= nil then
      overlays:registerOverlaySource("ucp/plugins/MyPlugin-*/resources/modsupport/building-overlays/")
    end

Modülünkiyle aynı adlı bir katman onun yerini alır. Save düğmesi o eklentinin konumlarını da `ucp` klasörüne yazar; eklentinin kendi `overlays.lua` dosyası olduğu gibi kalır.

Aynı dosya, panelin «Game #n» olarak listelediği oyunun kendi görsellerini de taşıyabilir.
