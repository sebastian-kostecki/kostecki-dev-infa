# Backupy (Vaultwarden + Obsidian LiveSync)

Ten dokument opisuje **jak skonfigurować, sprawdzić i odzyskać** kopie Vaultwarden i CouchDB (Obsidian LiveSync) na VPS.

## Co to jest, a czego nie robi

Na hoście (nie w Dockerze Traefika) codziennie odpalają się dwa joby systemd. Każdy:

1. robi **spójny zrzut danych** aplikacji do katalogu tymczasowego na `/storage`,
2. wrzuca ten zrzut do **zaszyfrowanego repozytorium restic**,
3. wycina stare snapshoty (schemat GFS),
4. kasuje katalog tymczasowy — **tylko gdy restic się udał**.

**To nie jest to samo co backup wallet-master.** Laravel i tak zrzuca bazy Spatie do `/storage/wallet-master-backups`. Tego systemu nie ruszamy i nie migrujemy na restic.

**Gdzie fizycznie leżą pliki:** `/storage` na VPS to mount z **innej maszyny**. Backup przeżyje reinstall OS-a VPS albo skasowanie volume Dockera, o ile mount i ta druga maszyna działają. To nadal nie jest trzecia kopia (S3/B2) — jej tu nie ma.

Specyfikacja decyzji: [superpowers/specs/2026-08-19-restic-backups-design.md](./superpowers/specs/2026-08-19-restic-backups-design.md) (po angielsku).

---

## Układ katalogów na `/storage`

```text
/storage/
├── wallet-master-backups/     ← Spatie (Laravel); restic tego nie czyta
├── restic/
│   ├── vaultwarden/           ← zaszyfrowane repo restic (same snapshoty, nie „luźny tar”)
│   └── obsidian-livesync/     ← drugie repo, inne hasło
└── backup-staging/
    ├── vaultwarden/           ← tylko w trakcie joba; po sukcesie znika
    └── obsidian-livesync/
```

**`restic/vaultwarden` i `restic/obsidian-livesync`** — to nie są foldery, które rozpakowujesz ręcznie. W środku jest format restic (`config`, `data/`, `index/`, `snapshots/`). Odczyt tylko przez `restic snapshots` / `restic restore` **z tym samym hasłem**, którym repo zainicjowano.

Dwa osobne repo = dwa osobne hasła. Wyciek jednego nie otwiera drugiego zestawu danych. Restore jednej apki nie wymaga ruszania drugiej.

**`backup-staging/`** — tu ląduje kopia *zanim* restic ją zaszyfruje. Jeśli job padnie na `restic backup`, ten katalog **zostaje** (żebyś mógł zobaczyć, co się zrzuciło, albo ponowić). Po udanym backupie skrypt go kasuje, żeby nie zjadać miejsca na mouncie.

---

## Hasła restic (nie idą do gita)

```text
/etc/restic/vaultwarden.password           właściciel root, prawa 600
/etc/restic/obsidian-livesync.password     to samo
```

**Po co plik, a nie zmienna w `.env` apki:** timery systemd odpalają się jako **root**, niezależnie od deployu Vaultwarden/LiveSync. Hasło musi być na hoście, poza repozytorium gita.

**Co jest w pliku:** jedna linia — długie losowe hasło (np. 32+ znaki). Bez spacji na końcu, bez cudzysłowów. To jest klucz szyfrowania całego repo. Zgubisz plik **i** kopię w menedżerze haseł → snapshoty na `/storage` są bezużytecznym szumem. Żywe dane w Dockerze nadal działają, ale **starych kopii nie odzyskasz**.

**Dlaczego dwa pliki:** inne repo = inne hasło. Nie kopiuj tego samego ciągu do obu plików.

**Jak wygenerować i zapisać (raz, na VPS, jako root):**

```bash
sudo mkdir -p /etc/restic
sudo chmod 700 /etc/restic

# przykładowo: 48 znaków z /dev/urandom, zapisane tylko do pliku
sudo install -m 600 /dev/null /etc/restic/vaultwarden.password
sudo install -m 600 /dev/null /etc/restic/obsidian-livesync.password
openssl rand -base64 36 | sudo tee /etc/restic/vaultwarden.password >/dev/null
openssl rand -base64 36 | sudo tee /etc/restic/obsidian-livesync.password >/dev/null
sudo chmod 600 /etc/restic/vaultwarden.password /etc/restic/obsidian-livesync.password
```

Od razu skopiuj obie wartości do menedżera haseł (Bitwarden / ten sam Vaultwarden — świadomie: hasło *kopii* vaulta trzymaj też poza tym vaultem, np. na kartce / w drugim managerze). Instalator **nie tworzy** tych plików; bez nich kończy się błędem `create /etc/restic/... then rerun`.

---

## Jednorazowa konfiguracja na VPS

Robisz to **raz** po wdrożeniu aplikacji, albo po reinstalacji OS-a. **Nie** wklejaj tego do `deploy-vaultwarden.sh` / `deploy-obsidian-livesync.sh` — każdy deploy nadpisywałby timery i mógłby odpalać `restic init`.

### 1. Sprawdź, że `/storage` to mount, nie pusty lokalny katalog

```bash
mountpoint /storage
df -h /storage
findmnt /storage
```

**Oczekiwane:** `mountpoint` wypisuje `/storage is a mountpoint`. `findmnt` pokazuje źródło (NFS, CIFS, virtiofs, drugi dysk — zależnie od Twojej drugiej maszyny).

**Jeśli nie jest zamontowane:** skrypty backupu **od razu wychodzą z błędem** (`ERROR: /storage is not a mountpoint`), żeby nie zainicjować restic na lokalnym dysku VPS i nie udawać, że kopia jest „poza maszyną”.

### 2. Utwórz pliki haseł

Jak w sekcji wyżej. Sprawdzenie:

```bash
sudo ls -la /etc/restic/
# dwa pliki, -rw------- 1 root root
sudo wc -c /etc/restic/*.password
# oba niezerowe
```

### 3. Zaktualizuj kod infra i odpal instalator

Instalator zakłada, że jesteś w klonie tego repo i że na VPS leży on w `/srv/infra` (ścieżki w unitach systemd są **sztywne**: `ExecStart=/srv/infra/scripts/backup-....sh`).

```bash
cd /srv/infra
git pull
sudo ./scripts/install-backup-timers.sh
```

**Co ten skrypt robi, linia po linii:**

| Krok | Znaczenie |
|------|-----------|
| Wymaga uid 0 | Bez `sudo` od razu exit 1 |
| `apt-get install restic` | Tylko gdy `restic` nie ma w `PATH` |
| `mkdir` repo i staging | Tworzy `/storage/restic/vaultwarden`, `.../obsidian-livesync`, `backup-staging`, `/etc/restic` |
| `chmod 700 /etc/restic` | Katalog haseł tylko dla root |
| Sprawdza oba pliki haseł | Brak pliku = stop, **bez** `restic init` |
| `restic init` | Tylko gdy w repo **nie ma** pliku `config` (świeże repo). Drugi raz ten sam katalog zostawia w spokoju |
| Kopiuje `systemd/*.service` i `*.timer` do `/etc/systemd/system/` | Nadpisuje jednostki, jeśli instalator odpalisz ponownie po zmianie timerów w gicie |
| `daemon-reload` + `enable --now` obu timerów | Włącza automat na stałe i startuje **timery** (nie od razu pełnego backupu o 03:00) |

Na końcu zobaczysz `systemctl list-timers 'backup-*'` — powinny być `backup-vaultwarden.timer` (następne **03:00** czasu **strefy VPS**) i `backup-obsidian-livesync.timer` (**03:20**).

`Persistent=true` w timerze: jeśli VPS spał przez 03:00, po starcie systemd **raz** odrobi zaległy job.

Godziny są po wallet-master (Spatie ~01:30), żeby nie walić trzema backupami w tej samej minucie. LiveSync jest 20 minut po Vaultwarden, żeby krótki `docker stop couchdb` nie nachodził na dump SQLite.

---

## Co robi codzienny job (żeby wiedzieć, czy „działa”)

### Vaultwarden — 03:00, kontener **zostaje włączony**

1. Sprawdza mount `/storage` i plik hasła oraz że istnieje katalog `/storage/restic/vaultwarden`.
2. Czyści i tworzy `/storage/backup-staging/vaultwarden`.
3. Alpine + `rsync` z volume `vaultwarden_vw-data` → staging: załączniki, `config.json`, klucze RSA itd. **Świadomie pomija** `db.sqlite3`, `db.sqlite3-wal`, `db.sqlite3-shm` (surowa kopia bazy w locie mogłaby być urwana).
4. Alpine + `sqlite3 /data/db.sqlite3 ".backup /staging/db.sqlite3"` — spójny snapshot SQLite do `staging/db.sqlite3` przy włączonym Vaultwarden.
5. `restic backup` tego stagingu do `/storage/restic/vaultwarden`.
6. `restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6`.
7. Kasuje staging.

Domyślna nazwa volume: `vaultwarden_vw-data` (projekt compose = katalog `/srv/apps/vaultwarden`). Inna nazwa: `docker volume ls | grep vw` i ewentualnie `VAULTWARDEN_VOLUME=...` w środowisku unit-a (teraz nie jest ustawiane — zmień skrypt/unit, jeśli u Ciebie volume nazywa się inaczej).

### Obsidian LiveSync — 03:20, CouchDB **krótko stoi**

1. Te same checki, staging `/storage/backup-staging/obsidian-livesync`.
2. `docker stop couchdb`.
3. Alpine kopiuje volume `obsidian-livesync_couchdb-data` do stagingu.
4. **`docker start couchdb` od razu po kopii**, jeszcze przed restic. Jeśli kopia padnie, `trap` i tak próbuje odpalić Couch — żeby LiveSync nie został wyłączony do rana.
5. `restic backup` + GFS + kasowanie stagingu.

Okno offline to czas `cp` volume, nie szyfrowanie restic. Klient Obsidian na telefonie i tak ma lokalny vault.

---

## Ręczny odpal i weryfikacja, że snapshot powstał

Nie czekaj do 03:00 przy pierwszym setupie. **Najpierw Vaultwarden, potem LiveSync** (LiveSync zrestartuje Couch na chwilę).

```bash
sudo systemctl start backup-vaultwarden.service
sudo systemctl start backup-obsidian-livesync.service
```

`start` na **service** (nie timer) = job **teraz**. Timer zostaje włączony jak był.

Logi tego konkretnego odpalenia:

```bash
journalctl -u backup-vaultwarden.service -u backup-obsidian-livesync.service -e
```

**Sukces:** na końcu `==> Vaultwarden backup complete` / `==> Obsidian LiveSync backup complete`, status `exited` z kodem 0.

**Częste błędy w logu:**

| Komunikat | Co zrobić |
|-----------|-----------|
| `/storage is not a mountpoint` | Napraw mount, potem ponów `systemctl start` |
| `missing restic password file` | Utwórz pliki z sekcji haseł |
| `restic repo missing` | Odpal `install-backup-timers.sh` (tworzy katalogi i `restic init`) |
| `No such volume: vaultwarden_vw-data` | `docker volume ls` — ustaw właściwą nazwę albo upewnij się, że compose raz wstał |
| `No such container: couchdb` | Kontener LiveSync nie działa; najpierw `deploy-obsidian-livesync.sh` |

Lista snapshotów (hasło z pliku, nie wpisujesz go w shell history jeśli używasz `PASSWORD_FILE`):

```bash
sudo RESTIC_REPOSITORY=/storage/restic/vaultwarden \
  RESTIC_PASSWORD_FILE=/etc/restic/vaultwarden.password \
  restic snapshots

sudo RESTIC_REPOSITORY=/storage/restic/obsidian-livesync \
  RESTIC_PASSWORD_FILE=/etc/restic/obsidian-livesync.password \
  restic snapshots
```

**Oczekiwane po pierwszym ręcznym runie:** w każdej komendzie **co najmniej jeden** wiersz snapshotu (ID, czas, host). Pusty listing = backup się nie zapisał, wróć do `journalctl`.

`latest` w restore oznacza **najnowszy** snapshot w tym repo, nie magiczny backup z konkretnego dnia. Do konkretnej daty użyj ID z kolumny `ID` z `restic snapshots`.

---

## Restore Vaultwarden (nadpisuje działający vault)

To **ręczna** procedura. Żaden cron tego nie robi. Zastępuje **całe** `/data` w volume aktualnym stanem z kopii — utracisz zmiany nowsze niż wybrany snapshot.

### 1. Wybierz snapshot

```bash
sudo RESTIC_REPOSITORY=/storage/restic/vaultwarden \
  RESTIC_PASSWORD_FILE=/etc/restic/vaultwarden.password \
  restic snapshots
```

Zapisz `ID` (np. `a1b2c3d4`) albo świadomie użyj `latest`.

### 2. Rozszyfruj snapshot na dysk VPS (jeszcze nie do Dockera)

```bash
sudo RESTIC_REPOSITORY=/storage/restic/vaultwarden \
  RESTIC_PASSWORD_FILE=/etc/restic/vaultwarden.password \
  restic restore latest --target /tmp/vw-restore
```

Restic zapisuje **pełną ścieżkę** z backupu. Skrypt backupuje katalog `/storage/backup-staging/vaultwarden`, więc po restore pliki **nie** leżą w `/tmp/vw-restore/db.sqlite3`, tylko np.:

```text
/tmp/vw-restore/storage/backup-staging/vaultwarden/db.sqlite3
/tmp/vw-restore/storage/backup-staging/vaultwarden/attachments/
...
```

Sprawdź zanim cokolwiek skasujesz w volume:

```bash
sudo find /tmp/vw-restore -name db.sqlite3
```

Katalog, w którym leży `db.sqlite3`, to katalog, który kopiujesz do `/data`.

### 3. Zatrzymaj Vaultwarden

```bash
docker stop vaultwarden
```

Inaczej baza i pliki będą nadpisywane w locie.

### 4. Wgraj pliki do volume `vaultwarden_vw-data`

Podmień `/restore` w helperze na **ten** katalog, który znalazł `find` (rodzic `db.sqlite3`):

```bash
# przykład — popraw ścieżkę po find
SRC=/tmp/vw-restore/storage/backup-staging/vaultwarden

docker run --rm \
  -v vaultwarden_vw-data:/data \
  -v "${SRC}:/restore:ro" \
  alpine:3.20 \
  sh -c 'rm -rf /data/* /data/.[!.]* /data/..?* ; cp -a /restore/. /data/'
```

To **kasuje** obecne `/data` w volume i kopiuje zawartość snapshotu. Zła ścieżka `SRC` (za wysoko, np. samo `/tmp/vw-restore`) wgra zagnieżdżone `storage/backup-staging/...` do `/data` i Vaultwarden nie znajdzie `db.sqlite3` w korzeniu.

Nazwę volume potwierdź: `docker volume ls | grep vw`.

### 5. Start i smoke-check

```bash
docker start vaultwarden
docker logs vaultwarden --tail 50
```

Otwórz `https://vault.kostecki.dev` i zaloguj się. Jeśli UI wstaje, a sejf jest pusty / stary — wybrałeś zły snapshot albo złą ścieżkę `SRC`.

Po udanym teście: `sudo rm -rf /tmp/vw-restore`.

---

## Restore CouchDB / LiveSync

Ten sam wzorzec, inne repo, kontener i volume.

```bash
sudo RESTIC_REPOSITORY=/storage/restic/obsidian-livesync \
  RESTIC_PASSWORD_FILE=/etc/restic/obsidian-livesync.password \
  restic snapshots

sudo RESTIC_REPOSITORY=/storage/restic/obsidian-livesync \
  RESTIC_PASSWORD_FILE=/etc/restic/obsidian-livesync.password \
  restic restore latest --target /tmp/couch-restore

sudo find /tmp/couch-restore -type d | head
# typowa zawartość danych Couch: katalog z .couch / shards — korzeń kopii to
# /tmp/couch-restore/storage/backup-staging/obsidian-livesync

docker stop couchdb

SRC=/tmp/couch-restore/storage/backup-staging/obsidian-livesync
docker run --rm \
  -v obsidian-livesync_couchdb-data:/data \
  -v "${SRC}:/restore:ro" \
  alpine:3.20 \
  sh -c 'rm -rf /data/* /data/.[!.]* /data/..?* ; cp -a /restore/. /data/'

docker start couchdb
```

Potem w Obsidianie: plugin Self-hosted LiveSync powinien zreplikować stan z serwera. Jeśli plugin ma **własne E2E** (hasło w kliencie), restore serwera przywraca ciphertext — bez hasła E2E wtyczki notatek nie odczytasz; to inne hasło niż restic.

Nazwa volume: `docker volume ls | grep couch`. Domyślnie `obsidian-livesync_couchdb-data`.

---

## Logi (nie ma maila ani Healthchecks)

Nie dostaniesz powiadomienia, gdy backup padnie. Raz na jakiś czas (albo po restarcie VPS):

```bash
systemctl status backup-vaultwarden.timer backup-obsidian-livesync.timer
```

Tu patrzysz, czy timer jest `enabled` / `active` i **kiedy następne** odpalenie.

```bash
journalctl -u backup-vaultwarden.service
journalctl -u backup-obsidian-livesync.service
```

Pełna historia jobów. `-e` skacze na koniec. `-b` = tylko od ostatniego bootu.

`systemctl status backup-vaultwarden.service` po nocnym runie często pokazuje `inactive (dead)` z `success` — oneshot tak ma. Ważny jest **wynik ostatniego** odpalenia (`Status:` / log), nie to, że service „nie działa” 24/7.

---

## Retencja GFS (co restic wyrzuca)

Po **każdym udanym** `restic backup` job woła:

```text
restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6
```

Oznacza to w praktyce:

- **7 dziennych** — ostatnie ~7 dni, po jednym na dobę,
- **4 tygodniowe** — starsze tygodnie, nie każdy dzień,
- **6 miesięcznych** — jeszcze starsze, zgrubnie po miesiącu.

`forget` oznacza snapshoty do usunięcia, `--prune` fizycznie zwalnia miejsce w `/storage/restic/...`. Nie licz na kopię sprzed roku — tego schemat nie trzyma.

Nie testujesz GFS w jeden dzień. Po pierwszym tygodniu `restic snapshots` powinno pokazać kilka dat, nie jedną.

---

## Czego ten system nie obejmuje

- wallet-master (Spatie),
- trzeciej kopii (S3 / `restic copy`),
- maila / Healthchecks,
- automatycznego restore.
