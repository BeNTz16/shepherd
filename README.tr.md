# Shepherd

```text
        /\_/\\
       ( o.o )   SHEPHERD
        > ^ <    Claude düşünsün, ağır işi sürü taşısın.
```

Claude Code çoban, Codex CLI çalışanları sürüdür. Shepherd; araştırma, kodlama ve inceleme işlerini model katmanları, efor sınırları, sandbox kipleri ve süre limitleriyle Codex'e yönlendirir.

## Neden

Claude kotasını planlama, yönlendirme ve son inceleme için koru. Ağır işi Codex CLI'ya ver. Kapsamı belirleme, diff inceleme, doğrulama ve son rapor Claude'da kalır.

## Nasıl çalışır

```text
Kullanıcı görevi
   |
   v
Claude Code: kapsamı belirle, böl
   |
   v
Shepherd: katman + efor + read/write + süre sınırı
   |
   v
Codex CLI çalışanı: proje dizininde sınırlı görev
   |
   v
Claude Code: diff'i incele, kontrolleri çalıştır, kabul et veya raporla
```

## 60 saniyede kurulum

```sh
SHEPHERD_REPO_URL=https://github.com/BeNTz16/shepherd.git bash install.sh
```

Bu komutu Shepherd checkout dizininde çalıştır. Kurucu depoyu `${XDG_DATA_HOME:-$HOME/.local/share}/shepherd` konumuna klonlar ve `$HOME/.claude/skills/shepherd` altında symlink kurar. Konumları değiştirmek için `SHEPHERD_CHECKOUT` veya `SHEPHERD_INSTALL_DIR` kullan. Dosyaları kopyalamak için `SHEPHERD_INSTALL_MODE=copy` ayarla. Uzak klon için `git` gerekir.

## Kullanım

1. Codex CLI kur ve giriş yap. Çalıştırıcı ayrıca `timeout`, `flock` ve `setsid` (util-linux) gerektirir.
2. `templates/AGENTS.delegation.md` dosyasını projenin köküne `AGENTS.md` adıyla kopyala. Yönlendirme kurallarını incele.
3. Claude Code'a hedef dosyaları ve kabul ölçütleri belli, sınırlı bir görev ver. Örnek: “`src/cache.php` neden eski değer döndürüyor, araştır. Yalnızca oku; kök nedeni dosya ve satırla, ayrıca en küçük düzeltme önerisiyle raporla.”
4. Claude araştırma ve inceleme için `read`, uygulama için `write` kipini seçer. Değişiklikleri inceler, kabul etmeden önce proje kontrollerini çalıştırır.

İstem dosyası görevi, tam hedef dosyaları, gerekli bağlamı, kısıtları ve ölçülebilir kabul ölçütlerini içermeli. İsteme sır koyma.

## Katmanlar

| Katman | Kullanım | Efor |
| --- | --- | --- |
| `luna` | Kolay düzeltme, hızlı araştırma, küçük uygulama | `low`–`high`; `xhigh`/`max` için `--escalate` gerekir |
| `sol` | Geniş kodlama işi, karmaşık hata, bağımsız inceleme | `medium`/`high`; yükseltilmiş `xhigh`; `low`/`max` yasak |
| `astra` | Alt katmanlar başarısız olduktan sonra son çare | Yalnızca `low`; `--escalate` gerekir |
| `reserve` | Başka katman kullanılamadığında alternatif | Yapılandırılmış sınır içinde `low`–`max` |

Örnek yapılandırmadaki model adları örnektir. Codex hesabında bulunan modellerle değiştir.

## Komut başvurusu

```text
"$HOME/.claude/skills/shepherd/scripts/shepherd-run.sh" <luna|sol|astra|reserve> <low|medium|high|xhigh|max> <read|write> <prompt-file> [workdir] [--escalate] [--critical]
```

Kurucu her iki kurulum kipinde çalıştırıcıya çalıştırma izni verir. Varsayılan kurulumdan sonra yukarıdaki yolu kullan; özel konum için `SHEPHERD_INSTALL_DIR` yolunu kullan. `workdir` varsayılan olarak geçerli dizindir. `--escalate` ve `--critical`, istem dosyasından veya çalışma dizininden sonra gelebilir. `read`, Codex'te `read-only`; `write`, `workspace-write` sandbox kullanır. Çalıştırıcı alt-ajanları devre dışı bırakır ve yapılandırılmış `sol` eşzamanlılık sınırını aşmaz.

| Seçenek | Etki |
| --- | --- |
| `--escalate` | Katmanın yükseltilmiş efor sınırını ve süre limitini seçer; `astra` için zorunludur. |
| `--critical` | `SHEPHERD_CRITICAL_TIER` (varsayılan `sol`) ve en az `SHEPHERD_CRITICAL_MIN_EFFORT` (varsayılan `high`) gerektirir; eskalasyonu etkinleştirmez. |
| `SHEPHERD_CONFIG` | Paket config yerine başka bir güvenilir shell config yükler. |

`write` görevinde çalıştırıcı diff istatistiklerini gösterir ve ayarlanmışsa `POST_WRITE_CHECK` çalıştırır. Günlükler ve raporlar `${SHEPHERD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/shepherd}` altında kısıtlı izinlerle tutulur.

## Çıkış kodları

| Kod | Anlam |
| --- | --- |
| `0` | Codex görevi ve varsa yazma sonrası kontrol başarılı. Yine de raporu ve diff'i incele. |
| `2` | Argüman, config, katman, efor, kip, istem veya çalışma dizini geçersiz. |
| `75` | Codex kotası tükendi. Bir kez `reserve` dene, sonra belgelenen Claude yedeğini kullan. |
| `76` | Tek devam denemesinden sonra Codex kapasitesi yoktu veya devam ettirilecek oturum bulunmadı. |
| `77` | `sol` eşzamanlılık yuvası için bekleme süresi doldu. |
| `124` | Görev zaman aşımına uğradı; kalan iş kısmi durumdadır. |
| `127` | Gerekli çalıştırılabilir dosya eksik: `codex`, `timeout`, `flock` veya `setsid`. |
| Diğer | Çalıştırıcı, Codex veya `POST_WRITE_CHECK` çıkış kodunu iletir. |

## Yapılandırma

Ortam değişkenleri paket varsayılanlarını geçersiz kılar. `config/shepherd.env` güvenilir shell kodudur; yalnızca güvendiğin config'i yükle.

`--escalate` olmadan `sol` ve `luna` için üst sınır sabit `high` değeridir. `--escalate` ile `SHEPHERD_SOL_MAX_EFFORT` ve `SHEPHERD_LUNA_MAX_EFFORT` üst sınırları belirler (varsayılanlar: `xhigh` ve `max`). `sol`, `low` ve `max` değerlerini yine reddeder.

| Değişken | Varsayılan | Amaç |
| --- | --- | --- |
| `SHEPHERD_MODEL_LUNA` | `gpt-6-luna` | `luna` modeli. |
| `SHEPHERD_MODEL_SOL` | `gpt-6.1-sol` | `sol` modeli. |
| `SHEPHERD_MODEL_ASTRA` | `gpt-6-astra` | `astra` modeli. |
| `SHEPHERD_MODEL_RESERVE` | `gpt-reserve` | `reserve` modeli. |
| `SHEPHERD_LUNA_MAX_EFFORT` | `max` | `--escalate` ile `luna` sınırı; aksi halde sınır `high`. |
| `SHEPHERD_SOL_MAX_EFFORT` | `xhigh` | `--escalate` ile `sol` sınırı; aksi halde sınır `high`. |
| `SHEPHERD_RESERVE_MAX_EFFORT` | `max` | `reserve` sınırı. |
| `SHEPHERD_TIMEOUT` | `420` | Normal görev süresi, saniye. |
| `SHEPHERD_ESCALATED_TIMEOUT` | `600` | Yükseltilmiş görev süresi, saniye. |
| `SHEPHERD_TIMEOUT_MAX` | `420` | Normal görev için en uzun süre, saniye. |
| `SHEPHERD_ESCALATED_TIMEOUT_MAX` | `600` | Yükseltilmiş görev için en uzun süre, saniye. |
| `SHEPHERD_RESUME_TIMEOUT` | `90` | Devam denemesi süresi, saniye. |
| `SHEPHERD_KILL_AFTER` | `10` | Zaman aşımından sonra kill sinyaline kadar geçen saniye. |
| `SHEPHERD_CAPACITY_WAIT` | `45` | Kapasite hatasından sonra devam etmeden önce bekleme, saniye. |
| `SHEPHERD_SOL_LIMIT` | `2` | İzin verilen eşzamanlı `sol` görevi. |
| `SHEPHERD_SLOT_WAIT` | `1800` | `sol` yuvası için en uzun bekleme, saniye. |
| `SHEPHERD_READ_SOFT_PERCENT` | `85` | Read görevleri için yumuşak süre sınırı yüzdesi. |
| `SHEPHERD_WRITE_SOFT_PERCENT` | `80` | Write görevleri için yumuşak süre sınırı yüzdesi. |
| `POST_WRITE_CHECK` | boş | Write görevlerinden sonra çalışma dizininde yürütülen güvenilir shell komutu. |
| `SHEPHERD_STATE_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/shepherd` | Özel günlükler, raporlar ve yuva kilitleri. |
| `SHEPHERD_REPO_URL` | boş | Uzak depodan kurulumda klonlama adresi. |
| `SHEPHERD_CHECKOUT` | `${XDG_DATA_HOME:-$HOME/.local/share}/shepherd` | `SHEPHERD_REPO_URL` ile kullanılan checkout yolu. |
| `SHEPHERD_INSTALL_DIR` | `$HOME/.claude/skills/shepherd` | Kurulu skill yolu. |
| `SHEPHERD_INSTALL_MODE` | `symlink` | `symlink` veya `copy`. |
| `XDG_DATA_HOME` | ayarlanmamış | Varsayılan checkout için temel yol. |
| `XDG_STATE_HOME` | ayarlanmamış | Varsayılan durum dizini için temel yol. |

## Güvenlik

- `read` salt okunur sandbox erişimi verir. `write`, çalışma alanına yazma izni verir. `write` kipini yalnızca uygulama görevlerinde kullan.
- Parolaları, API anahtarlarını, token'ları ve özel verileri istemlere koyma. Günlükler istemleri ve kaynak kodu içerebilir; durum dizinini koru.
- Shepherd config'i shell kodudur. Yalnızca güvenilir config kullan. `POST_WRITE_CHECK` de shell komutu olarak çalışır.
- Diff'leri ve kontrolleri incele. Son güvenlik ve veri kararları Claude'a aittir. Yıkıcı değişikliklerde proje onay kurallarına uy.

## Erken sürüm (v0.1)

Shepherd erken sürümdür. Kusurları olabilir ve geliştirilebilir. Çalışan çıktısını incele, önemli değişiklikleri doğrula.

## Yol haritası

- Kurulum ve yapılandırma açıklamalarını iyileştir.
- Gerçek kullanım örnekleri çıktıkça operasyon örnekleri ekle.
- Katman varsayılanlarını ölçüm sonuçlarına göre iyileştir.

## Katkı

Sorunu, önerilen değişikliği ve çalıştırılan kontrolleri içeren issue veya pull request aç. Görevleri sınırlı tut; somut ihtiyaç olmadan yapılandırma ekleme.

## İlgili projeler

- [sheepdog](https://github.com/BeNTz16/sheepdog): çok oturumlu koordinasyon panosu.
- [wolfhound](https://github.com/BeNTz16/wolfhound): güvenlik tarama skill'i.

Bunlar ayrı ve isteğe bağlı projelerdir. Shepherd tek başına çalışır.

## Lisans

MIT
