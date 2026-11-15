/// The short lists `Guesswork` looks words up in, each with its commonest
/// first, so a word's place is how soon a guesser would come to it. Written
/// out here from what people are known to choose, not copied from a list of
/// anybody's: the stems of the passwords that turn up in every leak, the
/// commonest English and Turkish words, and given names in both. The tail a
/// stem usually wears (`123`, a year, an exclamation mark) is not in them,
/// because the other matchers find it.
///
/// They are short on purpose, about nine hundred words against the hundred
/// thousand a full estimator carries, and that is the first reason the level
/// is an estimate (`docs/notes.md`, "How strong").
enum Words {
    /// A word and the place it holds in the list that has it soonest.
    static let ranks: [String: Int] = {
        var ranks: [String: Int] = [:]
        for list in [passwords, english, turkish, names] {
            for (place, word) in list.split(whereSeparator: \.isWhitespace).enumerated() {
                let word = String(word)
                ranks[word] = min(ranks[word] ?? .max, place + 1)
            }
        }
        return ranks
    }()

    /// The longest of them, which is as far as a lookup has to reach.
    static let longest = ranks.keys.map(\.count).max() ?? 0

    private static let passwords = """
        password qwerty abc letmein monkey dragon iloveyou master sunshine princess football baseball \
        welcome shadow superman michael login admin starwars hello freedom whatever trustno \
        batman zaq qazwsx ashley bailey access flower lovely secret killer hottie loveme jordan hunter \
        ranger buster soccer hockey george charlie andrew michelle love jennifer pepper ginger joshua \
        cheese amanda summer harley thomas robert matrix cookie tigger computer internet mustang \
        maggie test pass root user guest default changeme temp demo system server oracle mysql \
        nicole daniel jessica lakers yankees dallas austin thunder taylor chelsea arsenal liverpool \
        barcelona madrid juventus chicken banana orange purple silver golden diamond angel angels \
        babygirl lovers friends family forever samsung apple google facebook twitter linkedin \
        instagram snapchat minecraft pokemon naruto nintendo playstation xbox corvette ferrari \
        porsche mercedes yamaha honda toyota phoenix eagle eagles tiger tigers lion wolf wolves \
        spider scooter biteme maverick cowboy cowboys steelers packers warrior warriors merlin \
        wizard hacker passwort motdepasse contrasena senha parola sifre \
        sifrem galatasaray fenerbahce besiktas trabzonspor istanbul ankara izmir turkiye askim \
        canim seviyorum seniseviyorum ataturk qweasd asdasd qweqwe azerty zxcvbn asdfgh qwertyuiop \
        asdfghjkl zxcvbnm poiuyt mnbvcx lkjhgf trustme fuckyou fuckoff asshole bitch pussy sexy \
        blink jesus christ heaven god bismillah allah muhammad peace happy lucky smile sweet candy \
        chocolate butterfly rainbow unicorn midnight winter spring autumn monday friday january \
        october december
        """

    private static let english = """
        the and that have for not with you this but his from they say her she will one all would \
        there their what out about who get which when make can like time just him know take people \
        into year your good some could them see other than then now look only come its over think \
        also back after use two how our work first well way even new want because any these give \
        day most great where right still own life world down may man old big long small large high \
        house home school water food money night light dark black white red blue green yellow \
        brown pink gray friend girl boy woman child mother father sister brother baby king queen \
        prince city town country river mountain ocean island forest garden street road bridge \
        window door table chair book paper letter number word name game play music song dance \
        movie story news phone mail email web site page code key lock safe secure bank card \
        cash gold stone fire wind earth star moon sun sky cloud rain snow storm space rocket \
        planet dog cat bird fish horse bear rabbit mouse snake coffee tea beer wine bread pizza \
        sugar salt hot cold fast slow hard easy open close start stop begin end first last next \
        never always today tomorrow yesterday morning evening week month north south east west \
        left right top bottom front heart mind body hand head face eyes power energy magic \
        dream hope faith truth honor glory victory hero legend ghost demon devil death blood \
        sword shield arrow knight castle tower crown empire guard soldier army navy pilot \
        captain doctor nurse teacher student office company market store shop price sale buy \
        pay account member private public social media network cloud data file backup admin \
        correct battery staple horse apple please thank sorry hello goodbye welcome simple \
        strong weak short happy lucky crazy funny little pretty beautiful perfect awesome \
        super mega ultra alpha beta gamma delta omega zero one two three four five six seven \
        eight nine ten hundred thousand million
        """

    private static let turkish = """
        bir ve bu için ile ama çok daha gibi kadar ben sen biz siz onlar var yok evet hayır \
        ne kim nasıl neden nerede zaman gün gece sabah akşam hafta yıl bugün yarın dün ev iş \
        okul yol su ekmek para aşk sevgi seni beni canım aşkım hayat dünya deniz güneş yıldız \
        gök bulut yağmur kar ateş toprak dağ orman bahçe çiçek gül kedi köpek kuş balık at \
        aslan kartal kurt anne baba kardeş abla abi oğlum kızım bebek arkadaş dost güzel iyi \
        kötü büyük küçük yeni eski siyah beyaz kırmızı mavi yeşil sarı şifre parola giriş \
        merhaba selam hoşgeldin teşekkür lütfen tamam kalp ruh can gönül umut hayal mutlu \
        şans güç kral kraliçe prens prenses asker kaptan öğretmen doktor banka kart hesap \
        dükkan çalışma telefon bilgisayar oyun müzik şarkı kitap kalem masa kapı pencere \
        şehir köy memleket vatan bayrak cumhuriyet millet türk türkiye istanbul ankara izmir \
        bursa antalya adana konya trabzon samsun kayseri eskişehir bodrum kapadokya boğaz \
        ilkbahar yaz sonbahar kış ocak şubat mart nisan mayıs haziran temmuz ağustos eylül \
        ekim kasım aralık pazartesi salı çarşamba perşembe cuma cumartesi pazar bir iki üç \
        dört beş altı yedi sekiz dokuz on yüz bin milyon
        """

    private static let names = """
        james john robert michael william david richard joseph thomas charles mary patricia \
        jennifer linda elizabeth barbara susan jessica sarah karen daniel matthew anthony mark \
        paul steven andrew kevin brian george edward ryan jacob nicholas eric jonathan justin \
        scott brandon benjamin samuel alexander patrick jack peter henry adam nathan emma \
        olivia sophia isabella emily anna maria laura julia alice lucy grace chloe ella mia \
        mehmet mustafa ahmet ali hüseyin hasan ibrahim ismail osman yusuf murat ömer ramazan \
        halil süleyman abdullah mahmut recep salih fatih kadir emre hakan adem kemal yaşar \
        bekir musa metin serkan orhan burak gökhan furkan can cem deniz eren kaan mert meric \
        meriç onur ozan tolga umut volkan yiğit berk arda efe emir kerem fatma ayşe emine \
        hatice zeynep elif meryem şerife sultan hanife merve zehra esra özlem büşra yasemin \
        hülya melek dilek sevgi aylin selin ceren ebru gamze pınar seda tuğba derya ece \
        defne nehir azra ela irem
        """
}
