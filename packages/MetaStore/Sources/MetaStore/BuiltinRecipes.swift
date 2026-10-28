// GENERATED from avp-play recipes (MIT, github.com/myMartek/avp-play, recipes/*.json @ 22c8fe2):
// file ids, sizes and sha256 are theirs; destinations rewritten for Klepton's container layout
// (APK -> meta/, OBB and add-ons -> android-files/obb). One JSON document per recipe.
// batman.json: optional voice-language packs (`locale`). de-DE and en-US carry avp-play's size and
// sha256; the six it lists by id only (es-ES, es-419, fr-FR, it-IT, ja-JP, ko-KR) were measured
// 2026-10-12 by downloading each id from Meta's CDN with the owner's token (HTTP 200, Meta enforces
// ownership): size = the game's own localized-asset-manifest.txt, sha256 of the bytes received.
// ieytd: not from avp-play — app/binary ids, size and md5 from Meta's live release channel
// (2026-10-12); sha256 of that binary as downloaded by `metastore fetch ieytd --apk-only`.
// ktane: likewise from Meta's live release channel (2026-10-12); sha256 of that binary as fetched.
// re4: from avp-play recipes/store-2637179839719680.json (MIT); size and sha256 of the APK and both
// OBBs re-checked 2026-10-28 against the owner's Quest copy. UE4 builds its own OBB path, so the
// OBBs go to android-files/Android/obb/<package> (like Metro), not android-files/obb. Left out, as
// avp-play does: the unstripped engine .so (crash reports, 2.7 GB) and three Windows .bat files.
enum BuiltinRecipes {
    static let json: [String] = [
        #"""
{
 "schema": 1,
 "id": "beatsaber",
 "title": "Beat Saber",
 "package": "com.beatgames.beatsaber",
 "versionName": "1.40.8_7379",
 "versionCode": 1716,
 "appId": "2448060205267927",
 "target": "beatsaber",
 "files": [
  {
   "name": "beat-saber.apk",
   "role": "apk",
   "id": "30506607092319862",
   "size": 43406683,
   "sha256": "059bf468a1e6927cfe8fe8ce880589b9081c98c5bf5e40f726a188cc8932324e",
   "required": true,
   "dest": "meta"
  },
  {
   "name": "main.1716.com.beatgames.beatsaber.obb",
   "role": "main-obb",
   "id": "30506602615653643",
   "size": 1345687838,
   "sha256": "13fc1e957231820bed4c4189be36ccbd9083404594d3fce175b00443da09f0f5",
   "required": true,
   "dest": "android-files/obb"
  }
 ],
 "origin": "avp-play recipes/beatsaber140.json @ 22c8fe2 (MIT, github.com/myMartek/avp-play)",
 "addons": {
  "kind": "delivered-assets",
  "dest": "android-files/obb",
  "items": [
   {
    "sku": "P1S1",
    "name": "boundless",
    "id": "30506605242320047",
    "group": "monstercat"
   },
   {
    "sku": "P1S2",
    "name": "emojivip",
    "id": "30506605145653390",
    "group": "monstercat"
   },
   {
    "sku": "P1S3",
    "name": "epic",
    "id": "30506605108986727",
    "group": "monstercat"
   },
   {
    "sku": "P1S4",
    "name": "feelingstronger",
    "id": "30506604498986788",
    "group": "monstercat"
   },
   {
    "sku": "P1S5",
    "name": "overkill",
    "id": "30506604645653440",
    "group": "monstercat"
   },
   {
    "sku": "P1S6",
    "name": "rattlesnake",
    "id": "30506605165653388",
    "group": "monstercat"
   },
   {
    "sku": "P1S7",
    "name": "stronger",
    "id": "30506605212320050",
    "group": "monstercat"
   },
   {
    "sku": "P1S8",
    "name": "thistime",
    "id": "30506605332320038",
    "group": "monstercat"
   },
   {
    "sku": "P1S9",
    "name": "tillitsover",
    "id": "30506605318986706",
    "group": "monstercat"
   },
   {
    "sku": "P1S10",
    "name": "wewontbealone",
    "id": "30506605342320037",
    "group": "monstercat"
   },
   {
    "sku": "P2S1",
    "name": "badliar",
    "id": "30506605258986712",
    "group": "imaginedragons"
   },
   {
    "sku": "P2S2",
    "name": "believer",
    "id": "30506604778986760",
    "group": "imaginedragons"
   },
   {
    "sku": "P2S3",
    "name": "digital",
    "id": "30506605065653398",
    "group": "imaginedragons"
   },
   {
    "sku": "P2S4",
    "name": "itstime",
    "id": "30506605088986729",
    "group": "imaginedragons"
   },
   {
    "sku": "P2S5",
    "name": "machine",
    "id": "30506605298986708",
    "group": "imaginedragons"
   },
   {
    "sku": "P2S6",
    "name": "natural",
    "id": "30506604762320095",
    "group": "imaginedragons"
   },
   {
    "sku": "P2S7",
    "name": "radioactive",
    "id": "30506605275653377",
    "group": "imaginedragons"
   },
   {
    "sku": "P2S8",
    "name": "thunder",
    "id": "30506605305653374",
    "group": "imaginedragons"
   },
   {
    "sku": "P2S9",
    "name": "warriors",
    "id": "30506605292320042",
    "group": "imaginedragons"
   },
   {
    "sku": "P2S10",
    "name": "whateverittakes",
    "id": "30506604828986755",
    "group": "imaginedragons"
   },
   {
    "sku": "P2S11",
    "name": "bones",
    "id": "30506606038986634",
    "group": "imaginedragons"
   },
   {
    "sku": "P2S12",
    "name": "enemy",
    "id": "30506605228986715",
    "group": "imaginedragons"
   },
   {
    "sku": "P3S1",
    "name": "thegreatestshow",
    "id": "30506605272320044",
    "group": "panicatthedisco"
   },
   {
    "sku": "P3S2",
    "name": "victorious",
    "id": "30506604558986782",
    "group": "panicatthedisco"
   },
   {
    "sku": "P3S3",
    "name": "emperorsnewclothes",
    "id": "30506605058986732",
    "group": "panicatthedisco"
   },
   {
    "sku": "P3S4",
    "name": "highhopes",
    "id": "30506605252320046",
    "group": "panicatthedisco"
   },
   {
    "sku": "P3S5",
    "name": "crazygenius",
    "id": "30506604535653451",
    "group": "panicatthedisco"
   },
   {
    "sku": "P3S6",
    "name": "dancingsnotacrime",
    "id": "30506604652320106",
    "group": "panicatthedisco"
   },
   {
    "sku": "P3S7",
    "name": "heylookmaimadeit",
    "id": "30506604592320112",
    "group": "panicatthedisco"
   },
   {
    "sku": "P3S8",
    "name": "sayamen",
    "id": "30506604615653443",
    "group": "panicatthedisco"
   },
   {
    "sku": "P3S9",
    "name": "sugarsoaker",
    "id": "30506604532320118",
    "group": "panicatthedisco"
   },
   {
    "sku": "P3S10",
    "name": "vivalasvengeance",
    "id": "30506604642320107",
    "group": "panicatthedisco"
   },
   {
    "sku": "P4S1",
    "name": "play",
    "id": "30506605082320063",
    "group": "rocketleague"
   },
   {
    "sku": "P4S2",
    "name": "glide",
    "id": "30506605075653397",
    "group": "rocketleague"
   },
   {
    "sku": "P4S3",
    "name": "luvuneedu",
    "id": "30506605062320065",
    "group": "rocketleague"
   },
   {
    "sku": "P4S4",
    "name": "rockit",
    "id": "30506604825653422",
    "group": "rocketleague"
   },
   {
    "sku": "P4S5",
    "name": "shiawase",
    "id": "30506605245653380",
    "group": "rocketleague"
   },
   {
    "sku": "P4S6",
    "name": "testme",
    "id": "30506605248986713",
    "group": "rocketleague"
   },
   {
    "sku": "P5S1",
    "name": "americanidiot",
    "id": "30506605072320064",
    "group": "greenday",
    "size": 8964688,
    "sha256": "344cb9d738005a407461e7f7c6cc5bb248ea79de863463e968ef68caa7b1b474"
   },
   {
    "sku": "P5S2",
    "name": "fatherofall",
    "id": "30506605288986709",
    "group": "greenday",
    "size": 8486339,
    "sha256": "b9fc7694c2c0c1af76b91d207ef7075e900c75c6c8d082ec87c5320781f7c77b"
   },
   {
    "sku": "P5S3",
    "name": "boulevardofbrokendreams",
    "id": "30506604555653449",
    "group": "greenday",
    "size": 12940000,
    "sha256": "590b6c6a777babfec4219f317b2116a9cacf70b5f017113f166cbab92eda163f"
   },
   {
    "sku": "P5S4",
    "name": "holiday",
    "id": "30506604818986756",
    "group": "greenday",
    "size": 13041670,
    "sha256": "d8665e157551a6a45ff9673271babb57485531b8acc1d8bd0736dd029d77572a"
   },
   {
    "sku": "P5S5",
    "name": "firereadyaim",
    "id": "30506605285653376",
    "group": "greenday",
    "size": 6384906,
    "sha256": "1c6794850e9aff7abe9d157a4dbb1bd5bd5d1f696b3e7883cab3b486ed041b4c"
   },
   {
    "sku": "P5S6",
    "name": "minority",
    "id": "30506604572320114",
    "group": "greenday",
    "size": 9574032,
    "sha256": "2a7babad6095c5d347684e476a0ed2823510511a89c03f6e1fca9d345c708b0e"
   },
   {
    "sku": "P6S1",
    "name": "hasameaning",
    "id": "30506604658986772",
    "group": "timbaland"
   },
   {
    "sku": "P6S2",
    "name": "dumbthingz",
    "id": "30506605308986707",
    "group": "timbaland"
   },
   {
    "sku": "P6S3",
    "name": "whilewereyoung",
    "id": "30506606025653302",
    "group": "timbaland"
   },
   {
    "sku": "P6S4",
    "name": "whatilike",
    "id": "30506605055653399",
    "group": "timbaland"
   },
   {
    "sku": "P6S5",
    "name": "famous",
    "id": "30506604748986763",
    "group": "timbaland"
   },
   {
    "sku": "P7S1",
    "name": "bleeditout",
    "id": "30506605928986645",
    "group": "linkinpark"
   },
   {
    "sku": "P7S2",
    "name": "breakingthehabit",
    "id": "30506605888986649",
    "group": "linkinpark"
   },
   {
    "sku": "P7S3",
    "name": "faint",
    "id": "30506606048986633",
    "group": "linkinpark"
   },
   {
    "sku": "P7S4",
    "name": "givenup",
    "id": "30506605902319981",
    "group": "linkinpark"
   },
   {
    "sku": "P7S5",
    "name": "intheend",
    "id": "30506605935653311",
    "group": "linkinpark"
   },
   {
    "sku": "P7S6",
    "name": "newdivide",
    "id": "30506605895653315",
    "group": "linkinpark"
   },
   {
    "sku": "P7S7",
    "name": "numb",
    "id": "30506605912319980",
    "group": "linkinpark"
   },
   {
    "sku": "P7S8",
    "name": "onestepcloser",
    "id": "30506605892319982",
    "group": "linkinpark"
   },
   {
    "sku": "P7S9",
    "name": "papercut",
    "id": "30506605955653309",
    "group": "linkinpark"
   },
   {
    "sku": "P7S10",
    "name": "somewhereibelong",
    "id": "30506605942319977",
    "group": "linkinpark"
   },
   {
    "sku": "P7S11",
    "name": "whativedone",
    "id": "30506606058986632",
    "group": "linkinpark"
   },
   {
    "sku": "P8S1",
    "name": "bloodsweatandtears",
    "id": "30506605882319983",
    "group": "bts"
   },
   {
    "sku": "P8S2",
    "name": "boywithluv",
    "id": "30506605925653312",
    "group": "bts"
   },
   {
    "sku": "P8S3",
    "name": "burningup",
    "id": "30506605918986646",
    "group": "bts"
   },
   {
    "sku": "P8S4",
    "name": "dionysus",
    "id": "30506605968986641",
    "group": "bts"
   },
   {
    "sku": "P8S5",
    "name": "dna",
    "id": "30506605915653313",
    "group": "bts"
   },
   {
    "sku": "P8S6",
    "name": "dope",
    "id": "30506605922319979",
    "group": "bts"
   },
   {
    "sku": "P8S7",
    "name": "dynamite",
    "id": "30506605952319976",
    "group": "bts"
   },
   {
    "sku": "P8S8",
    "name": "fakelove",
    "id": "30506605932319978",
    "group": "bts"
   },
   {
    "sku": "P8S9",
    "name": "idol",
    "id": "30506605908986647",
    "group": "bts"
   },
   {
    "sku": "P8S10",
    "name": "micdrop",
    "id": "30506605855653319",
    "group": "bts"
   },
   {
    "sku": "P8S11",
    "name": "nottoday",
    "id": "30506605938986644",
    "group": "bts"
   },
   {
    "sku": "P8S12",
    "name": "ugh",
    "id": "30506605945653310",
    "group": "bts"
   },
   {
    "sku": "P9S1",
    "name": "countingstars",
    "id": "30506604738986764",
    "group": "interscope"
   },
   {
    "sku": "P9S2",
    "name": "dnalamar",
    "id": "30506604632320108",
    "group": "interscope"
   },
   {
    "sku": "P9S3",
    "name": "dontcha",
    "id": "30506604702320101",
    "group": "interscope"
   },
   {
    "sku": "P9S4",
    "name": "partyrockanthem",
    "id": "30506604595653445",
    "group": "interscope"
   },
   {
    "sku": "P9S5",
    "name": "rollin",
    "id": "30506605295653375",
    "group": "interscope"
   },
   {
    "sku": "P9S6",
    "name": "sugar",
    "id": "30506604795653425",
    "group": "interscope"
   },
   {
    "sku": "P9S7",
    "name": "thesweetescape",
    "id": "30506605312320040",
    "group": "interscope"
   },
   {
    "sku": "P10S1",
    "name": "bangarang",
    "id": "30506604752320096",
    "group": "skrillex"
   },
   {
    "sku": "P10S2",
    "name": "butterflies",
    "id": "30506605302320041",
    "group": "skrillex"
   },
   {
    "sku": "P10S3",
    "name": "dontgo",
    "id": "30506604735653431",
    "group": "skrillex"
   },
   {
    "sku": "P10S4",
    "name": "firstoftheyear",
    "id": "30506605278986710",
    "group": "skrillex"
   },
   {
    "sku": "P10S5",
    "name": "raggabomb",
    "id": "30506604775653427",
    "group": "skrillex"
   },
   {
    "sku": "P10S6",
    "name": "rocknroll",
    "id": "30506605098986728",
    "group": "skrillex"
   },
   {
    "sku": "P10S7",
    "name": "scarymonstersandnicesprites",
    "id": "30506605382320033",
    "group": "skrillex"
   },
   {
    "sku": "P10S8",
    "name": "thedevilsden",
    "id": "30506604695653435",
    "group": "skrillex"
   },
   {
    "sku": "P11S1",
    "name": "allthegoodgirlsgotohell",
    "id": "30506604768986761",
    "group": "billieeilish"
   },
   {
    "sku": "P11S2",
    "name": "badguy",
    "id": "30506604585653446",
    "group": "billieeilish"
   },
   {
    "sku": "P11S3",
    "name": "bellyache",
    "id": "30506604628986775",
    "group": "billieeilish"
   },
   {
    "sku": "P11S4",
    "name": "buryafriend",
    "id": "30506604625653442",
    "group": "billieeilish"
   },
   {
    "sku": "P11S5",
    "name": "happierthanever",
    "id": "30506604755653429",
    "group": "billieeilish"
   },
   {
    "sku": "P11S6",
    "name": "ididntchangemynumber",
    "id": "30506605102320061",
    "group": "billieeilish"
   },
   {
    "sku": "P11S7",
    "name": "nda",
    "id": "30506605352320036",
    "group": "billieeilish"
   },
   {
    "sku": "P11S8",
    "name": "oxytocin",
    "id": "30506604722320099",
    "group": "billieeilish"
   },
   {
    "sku": "P11S9",
    "name": "thereforeiam",
    "id": "30506605095653395",
    "group": "billieeilish"
   },
   {
    "sku": "P11S10",
    "name": "youshouldseemeinacrown",
    "id": "30506605078986730",
    "group": "billieeilish"
   },
   {
    "sku": "P12S1",
    "name": "alejandro",
    "id": "30506604725653432",
    "group": "ladygaga"
   },
   {
    "sku": "P12S2",
    "name": "badromance",
    "id": "30506605085653396",
    "group": "ladygaga"
   },
   {
    "sku": "P12S3",
    "name": "bornthisway",
    "id": "30506604732320098",
    "group": "ladygaga"
   },
   {
    "sku": "P12S4",
    "name": "justdance",
    "id": "30506604728986765",
    "group": "ladygaga"
   },
   {
    "sku": "P12S5",
    "name": "paparazzi",
    "id": "30506604552320116",
    "group": "ladygaga"
   },
   {
    "sku": "P12S6",
    "name": "pokerface",
    "id": "30506604708986767",
    "group": "ladygaga"
   },
   {
    "sku": "P12S7",
    "name": "rainonme",
    "id": "30506604718986766",
    "group": "ladygaga"
   },
   {
    "sku": "P12S8",
    "name": "stupidlove",
    "id": "30506605265653378",
    "group": "ladygaga"
   },
   {
    "sku": "P12S9",
    "name": "telephone",
    "id": "30506604588986779",
    "group": "ladygaga"
   },
   {
    "sku": "P12S10",
    "name": "theedgeofglory",
    "id": "30506605068986731",
    "group": "ladygaga"
   },
   {
    "sku": "P13S1",
    "name": "centuries",
    "id": "30506605092320062",
    "group": "falloutboy"
   },
   {
    "sku": "P13S2",
    "name": "dancedance",
    "id": "30506604792320092",
    "group": "falloutboy"
   },
   {
    "sku": "P13S3",
    "name": "idontcare",
    "id": "30506604805653424",
    "group": "falloutboy"
   },
   {
    "sku": "P13S4",
    "name": "immortals",
    "id": "30506604698986768",
    "group": "falloutboy"
   },
   {
    "sku": "P13S5",
    "name": "irresistible",
    "id": "30506604582320113",
    "group": "falloutboy"
   },
   {
    "sku": "P13S6",
    "name": "mysongsknow",
    "id": "30506604745653430",
    "group": "falloutboy"
   },
   {
    "sku": "P13S7",
    "name": "thisaintascene",
    "id": "30506604692320102",
    "group": "falloutboy"
   },
   {
    "sku": "P13S8",
    "name": "thnksfrthmmrs",
    "id": "30506604578986780",
    "group": "falloutboy"
   },
   {
    "sku": "P14S1",
    "name": "alone",
    "id": "30506604715653433",
    "group": "edm"
   },
   {
    "sku": "P14S2",
    "name": "animals",
    "id": "30506604548986783",
    "group": "edm"
   },
   {
    "sku": "P14S3",
    "name": "freestyler",
    "id": "30506604772320094",
    "group": "edm"
   },
   {
    "sku": "P14S4",
    "name": "ghostsnstuff",
    "id": "30506604542320117",
    "group": "edm"
   },
   {
    "sku": "P14S5",
    "name": "icarus",
    "id": "30506604832320088",
    "group": "edm"
   },
   {
    "sku": "P14S6",
    "name": "sandstorm",
    "id": "30506604802320091",
    "group": "edm"
   },
   {
    "sku": "P14S7",
    "name": "staythenight",
    "id": "30506604712320100",
    "group": "edm"
   },
   {
    "sku": "P14S8",
    "name": "therockafellerskank",
    "id": "30506604565653448",
    "group": "edm"
   },
   {
    "sku": "P14S9",
    "name": "waitingallnight",
    "id": "30506604575653447",
    "group": "edm"
   },
   {
    "sku": "P14S10",
    "name": "witchcraft",
    "id": "30506604742320097",
    "group": "edm"
   },
   {
    "sku": "P15S1",
    "name": "2beloved",
    "id": "30506605898986648",
    "group": "lizzo"
   },
   {
    "sku": "P15S2",
    "name": "aboutdamntime",
    "id": "30506604808986757",
    "group": "lizzo"
   },
   {
    "sku": "P15S3",
    "name": "cuziloveyou",
    "id": "30506604538986784",
    "group": "lizzo"
   },
   {
    "sku": "P15S4",
    "name": "everybodysgay",
    "id": "30506605348986703",
    "group": "lizzo"
   },
   {
    "sku": "P15S5",
    "name": "goodashell",
    "id": "30506604525653452",
    "group": "lizzo"
   },
   {
    "sku": "P15S6",
    "name": "juice",
    "id": "30506605355653369",
    "group": "lizzo"
   },
   {
    "sku": "P15S7",
    "name": "tempo",
    "id": "30506605868986651",
    "group": "lizzo"
   },
   {
    "sku": "P15S8",
    "name": "truthhurts",
    "id": "30506605345653370",
    "group": "lizzo"
   },
   {
    "sku": "P15S9",
    "name": "worship",
    "id": "30506604758986762",
    "group": "lizzo"
   },
   {
    "sku": "P16S1",
    "name": "blindinglights",
    "id": "30506604788986759",
    "group": "theweeknd"
   },
   {
    "sku": "P16S2",
    "name": "cantfeelmyface",
    "id": "30506605215653383",
    "group": "theweeknd"
   },
   {
    "sku": "P16S3",
    "name": "howdoimakeyouloveme",
    "id": "30506605378986700",
    "group": "theweeknd"
   },
   {
    "sku": "P16S4",
    "name": "ifeelitcoming",
    "id": "30506605315653373",
    "group": "theweeknd"
   },
   {
    "sku": "P16S5",
    "name": "prayforme",
    "id": "30506605112320060",
    "group": "theweeknd"
   },
   {
    "sku": "P16S6",
    "name": "sacrifice",
    "id": "30506605135653391",
    "group": "theweeknd"
   },
   {
    "sku": "P16S7",
    "name": "saveyourtears",
    "id": "30506605132320058",
    "group": "theweeknd"
   },
   {
    "sku": "P16S8",
    "name": "starboy",
    "id": "30506605198986718",
    "group": "theweeknd"
   },
   {
    "sku": "P16S9",
    "name": "takemybreath",
    "id": "30506604765653428",
    "group": "theweeknd"
   },
   {
    "sku": "P16S10",
    "name": "thehills",
    "id": "30506605175653387",
    "group": "theweeknd"
   },
   {
    "sku": "P16S11",
    "name": "dieforyou",
    "id": "30506604638986774",
    "group": "theweeknd"
   },
   {
    "sku": "P16S12",
    "name": "lessthanzero",
    "id": "30506604798986758",
    "group": "theweeknd"
   },
   {
    "sku": "P17S1",
    "name": "borntobewild",
    "id": "30506605225653382",
    "group": "rockmixtape",
    "size": 12756447,
    "sha256": "340e685a90d1a82d9d93aeb92a2b28a77d56e7d368b8dd0ef9752e1da0a5badf"
   },
   {
    "sku": "P17S2",
    "name": "eyeofthetiger",
    "id": "30506604678986770",
    "group": "rockmixtape",
    "size": 15098200,
    "sha256": "53f169fe32e40d6b3be4da61b6f5e4c53c0f66c490d12e5132060be71d45928e"
   },
   {
    "sku": "P17S3",
    "name": "freebird",
    "id": "30506604618986776",
    "group": "rockmixtape",
    "size": 27187213,
    "sha256": "d63da23c0df25f084e55f83c7735fce7846c7ccb0f2f9557e528036aa58318f2"
   },
   {
    "sku": "P17S4",
    "name": "iwasmadelovingyou",
    "id": "30506605125653392",
    "group": "rockmixtape",
    "size": 15397327,
    "sha256": "78c834998352896521c99ea7340043aac34699cb284c6c9fc6ebcd50ab7d6823"
   },
   {
    "sku": "P17S5",
    "name": "sevennationarmy",
    "id": "30506604512320120",
    "group": "rockmixtape",
    "size": 11282513,
    "sha256": "e5cd7c11dacb801a2a0485481dbf9641d77a87494a6ed33b9670448f16aa5e84"
   },
   {
    "sku": "P17S6",
    "name": "smellsliketeenspirit",
    "id": "30506605975653307",
    "group": "rockmixtape",
    "size": 17513217,
    "sha256": "1d359c5b156924095d0c72419ed8fc93a91165c18d5d167eee28f82a944bf688"
   },
   {
    "sku": "P17S7",
    "name": "sweetchildomine",
    "id": "30506605872319984",
    "group": "rockmixtape",
    "size": 20768264,
    "sha256": "6f0a6881b3c741505fdd3cfe01101d3b916fb0abb8ed7473cd0816352515a967"
   },
   {
    "sku": "P17S8",
    "name": "thepretender",
    "id": "30506604518986786",
    "group": "rockmixtape",
    "size": 14837029,
    "sha256": "b56e99ddd3ecb3a69dd6418e67a19aff38074851801ec139cdbf2262589e83ca"
   },
   {
    "sku": "P18S1",
    "name": "anotheronebitesthedust",
    "id": "30506605168986721",
    "group": "queen"
   },
   {
    "sku": "P18S2",
    "name": "bohemianrhapsody",
    "id": "30506604782320093",
    "group": "queen"
   },
   {
    "sku": "P18S3",
    "name": "crazylittlethingcalledlove",
    "id": "30506606032319968",
    "group": "queen"
   },
   {
    "sku": "P18S4",
    "name": "dontstopmenow",
    "id": "30506605988986639",
    "group": "queen"
   },
   {
    "sku": "P18S5",
    "name": "iwantitall",
    "id": "30506604612320110",
    "group": "queen"
   },
   {
    "sku": "P18S6",
    "name": "killerqueen",
    "id": "30506605375653367",
    "group": "queen"
   },
   {
    "sku": "P18S7",
    "name": "onevision",
    "id": "30506605188986719",
    "group": "queen"
   },
   {
    "sku": "P18S8",
    "name": "somebodytolove",
    "id": "30506605995653305",
    "group": "queen"
   },
   {
    "sku": "P18S9",
    "name": "stonecoldcrazy",
    "id": "30506606012319970",
    "group": "queen"
   },
   {
    "sku": "P18S10",
    "name": "wearethechampions",
    "id": "30506604502320121",
    "group": "queen"
   },
   {
    "sku": "P18S11",
    "name": "wewillrockyou",
    "id": "30506605238986714",
    "group": "queen"
   },
   {
    "sku": "P19S1",
    "name": "alreadyover",
    "id": "30506604812320090",
    "group": "linkinpark2"
   },
   {
    "sku": "P19S2",
    "name": "crawling",
    "id": "30506605875653317",
    "group": "linkinpark2"
   },
   {
    "sku": "P19S3",
    "name": "fightingmyself",
    "id": "30506604662320105",
    "group": "linkinpark2"
   },
   {
    "sku": "P19S4",
    "name": "inmyhead",
    "id": "30506605862319985",
    "group": "linkinpark2"
   },
   {
    "sku": "P19S5",
    "name": "lost",
    "id": "30506605142320057",
    "group": "linkinpark2"
   },
   {
    "sku": "P19S6",
    "name": "morethevictim",
    "id": "30506604568986781",
    "group": "linkinpark2"
   },
   {
    "sku": "P19S7",
    "name": "numbencore",
    "id": "30506606005653304",
    "group": "linkinpark2"
   },
   {
    "sku": "P19S8",
    "name": "rememberthename",
    "id": "30506605885653316",
    "group": "linkinpark2"
   },
   {
    "sku": "P20S1",
    "name": "angry",
    "id": "30506605992319972",
    "group": "therollingstones"
   },
   {
    "sku": "P20S2",
    "name": "bitemyheadoff",
    "id": "30506606035653301",
    "group": "therollingstones"
   },
   {
    "sku": "P20S3",
    "name": "cantyouhearmeknocking",
    "id": "30506605162320055",
    "group": "therollingstones"
   },
   {
    "sku": "P20S4",
    "name": "gimmeshelter",
    "id": "30506605118986726",
    "group": "therollingstones"
   },
   {
    "sku": "P20S5",
    "name": "icantgetnosatisfaction",
    "id": "30506606002319971",
    "group": "therollingstones"
   },
   {
    "sku": "P20S6",
    "name": "livebythesword",
    "id": "30506605328986705",
    "group": "therollingstones"
   },
   {
    "sku": "P20S7",
    "name": "messitup",
    "id": "30506605368986701",
    "group": "therollingstones"
   },
   {
    "sku": "P20S8",
    "name": "paintitblack",
    "id": "30506605138986724",
    "group": "therollingstones"
   },
   {
    "sku": "P20S9",
    "name": "startmeup",
    "id": "30506605365653368",
    "group": "therollingstones"
   },
   {
    "sku": "P20S10",
    "name": "sympathyforthedevil",
    "id": "30506604705653434",
    "group": "therollingstones"
   },
   {
    "sku": "P20S11",
    "name": "wholewideworld",
    "id": "30506605155653389",
    "group": "therollingstones"
   },
   {
    "sku": "P21S1",
    "name": "aroundtheworld",
    "id": "30506604672320104",
    "group": "daftpunk"
   },
   {
    "sku": "P21S2",
    "name": "aroundtheworldharderbetterfasterstronger",
    "id": "30506604528986785",
    "group": "daftpunk"
   },
   {
    "sku": "P21S3",
    "name": "dafunkdaftendirekt",
    "id": "30506605232320048",
    "group": "daftpunk"
   },
   {
    "sku": "P21S4",
    "name": "getlucky",
    "id": "30506605962319975",
    "group": "daftpunk"
   },
   {
    "sku": "P21S5",
    "name": "harderbetterfasterstronger",
    "id": "30506606015653303",
    "group": "daftpunk"
   },
   {
    "sku": "P21S6",
    "name": "loseyourselftodance",
    "id": "30506605325653372",
    "group": "daftpunk"
   },
   {
    "sku": "P21S7",
    "name": "onemoretime",
    "id": "30506605958986642",
    "group": "daftpunk"
   },
   {
    "sku": "P21S8",
    "name": "technologic",
    "id": "30506604508986787",
    "group": "daftpunk"
   },
   {
    "sku": "P21S9",
    "name": "primetimeofyourlifebrainwasherrollinalivelive2007",
    "id": "30506605192320052",
    "group": "daftpunk"
   },
   {
    "sku": "P21S10",
    "name": "veridisquo",
    "id": "30506605115653393",
    "group": "daftpunk"
   },
   {
    "sku": "P22S1",
    "name": "alleyezonme",
    "id": "30506604562320115",
    "group": "hiphop"
   },
   {
    "sku": "P22S2",
    "name": "anaconda",
    "id": "30506605158986722",
    "group": "hiphop"
   },
   {
    "sku": "P22S3",
    "name": "ginandjuice",
    "id": "30506605182320053",
    "group": "hiphop"
   },
   {
    "sku": "P22S4",
    "name": "godzilla",
    "id": "30506604675653437",
    "group": "hiphop"
   },
   {
    "sku": "P22S5",
    "name": "heyya",
    "id": "30506605268986711",
    "group": "hiphop"
   },
   {
    "sku": "P22S6",
    "name": "hypnotize",
    "id": "30506604822320089",
    "group": "hiphop"
   },
   {
    "sku": "P22S7",
    "name": "nuthinbutagthang",
    "id": "30506604602320111",
    "group": "hiphop"
   },
   {
    "sku": "P22S8",
    "name": "themessage",
    "id": "30506605218986716",
    "group": "hiphop"
   },
   {
    "sku": "P22S9",
    "name": "thewoo",
    "id": "30506604505653454",
    "group": "hiphop"
   },
   {
    "sku": "P23S1",
    "name": "houdini",
    "id": "30506605338986704",
    "group": "shockdrop"
   },
   {
    "sku": "P23S2",
    "name": "notlikeus",
    "id": "30506606008986637",
    "group": "shockdrop"
   },
   {
    "sku": "P23S3",
    "name": "abracadabra",
    "id": "30506604492320122",
    "group": "shockdrop"
   },
   {
    "sku": "P23S4",
    "name": "birdsofafeather",
    "id": "30506605905653314",
    "group": "shockdrop"
   },
   {
    "sku": "P23S5",
    "name": "espresso",
    "id": "30506605878986650",
    "group": "shockdrop"
   },
   {
    "sku": "P24S1",
    "name": "babyonemoretime",
    "id": "30506604635653441",
    "group": "britneyspears"
   },
   {
    "sku": "P24S2",
    "name": "circus",
    "id": "30506604665653438",
    "group": "britneyspears"
   },
   {
    "sku": "P24S3",
    "name": "gimmemore",
    "id": "30506605978986640",
    "group": "britneyspears"
   },
   {
    "sku": "P24S4",
    "name": "imaslave4u",
    "id": "30506604608986777",
    "group": "britneyspears"
   },
   {
    "sku": "P24S5",
    "name": "meagainstthemusic",
    "id": "30506605982319973",
    "group": "britneyspears"
   },
   {
    "sku": "P24S6",
    "name": "oopsididitagain",
    "id": "30506605205653384",
    "group": "britneyspears"
   },
   {
    "sku": "P24S7",
    "name": "overprotected",
    "id": "30506605972319974",
    "group": "britneyspears"
   },
   {
    "sku": "P24S8",
    "name": "scream&shout",
    "id": "30506606018986636",
    "group": "britneyspears"
   },
   {
    "sku": "P24S9",
    "name": "tilltheworldends",
    "id": "30506606045653300",
    "group": "britneyspears"
   },
   {
    "sku": "P24S10",
    "name": "toxic",
    "id": "30506605358986702",
    "group": "britneyspears"
   },
   {
    "sku": "P24S11",
    "name": "womanizer",
    "id": "30506605985653306",
    "group": "britneyspears"
   },
   {
    "sku": "P25S1",
    "name": "accelerate",
    "id": "30506605185653386",
    "group": "monstercatvol2"
   },
   {
    "sku": "P25S2",
    "name": "dabadabadabadaba",
    "id": "30506606052319966",
    "group": "monstercatvol2"
   },
   {
    "sku": "P25S3",
    "name": "deadmanwalking",
    "id": "30506605335653371",
    "group": "monstercatvol2"
   },
   {
    "sku": "P25S4",
    "name": "endgame",
    "id": "30506605122320059",
    "group": "monstercatvol2"
   },
   {
    "sku": "P25S5",
    "name": "finalboss",
    "id": "30506605948986643",
    "group": "monstercatvol2"
   },
   {
    "sku": "P25S6",
    "name": "memorybank",
    "id": "30506605865653318",
    "group": "monstercatvol2"
   },
   {
    "sku": "P25S7",
    "name": "mercenary",
    "id": "30506606028986635",
    "group": "monstercatvol2"
   },
   {
    "sku": "P25S8",
    "name": "pump",
    "id": "30506605148986723",
    "group": "monstercatvol2"
   },
   {
    "sku": "P25S9",
    "name": "rad",
    "id": "30506604682320103",
    "group": "monstercatvol2"
   },
   {
    "sku": "P25S10",
    "name": "riot",
    "id": "30506605052320066",
    "group": "monstercatvol2"
   },
   {
    "sku": "P25S11",
    "name": "thronesofblood",
    "id": "30506604605653444",
    "group": "monstercatvol2"
   },
   {
    "sku": "P25S12",
    "name": "wakeup",
    "id": "30506606022319969",
    "group": "monstercatvol2"
   },
   {
    "sku": "P26S1",
    "name": "atlasrise",
    "id": "30506606042319967",
    "group": "metallica"
   },
   {
    "sku": "P26S2",
    "name": "battery",
    "id": "30506605128986725",
    "group": "metallica"
   },
   {
    "sku": "P26S3",
    "name": "blackened",
    "id": "30506604545653450",
    "group": "metallica"
   },
   {
    "sku": "P26S4",
    "name": "creepingdeath",
    "id": "30506605858986652",
    "group": "metallica"
   },
   {
    "sku": "P26S5",
    "name": "entersandman",
    "id": "30506605255653379",
    "group": "metallica"
   },
   {
    "sku": "P26S6",
    "name": "fadetoblack",
    "id": "30506604785653426",
    "group": "metallica"
   },
   {
    "sku": "P26S7",
    "name": "forwhomthebelltolls",
    "id": "30506604598986778",
    "group": "metallica"
   },
   {
    "sku": "P26S8",
    "name": "fuel",
    "id": "30506605195653385",
    "group": "metallica"
   },
   {
    "sku": "P26S9",
    "name": "hitthelights",
    "id": "30506604815653423",
    "group": "metallica"
   },
   {
    "sku": "P26S10",
    "name": "kingnothing",
    "id": "30506604668986771",
    "group": "metallica"
   },
   {
    "sku": "P26S11",
    "name": "luxaeterna",
    "id": "30506605152320056",
    "group": "metallica"
   },
   {
    "sku": "P26S12",
    "name": "masterofpuppets",
    "id": "30506604622320109",
    "group": "metallica"
   },
   {
    "sku": "P26S13",
    "name": "nothingelsematters",
    "id": "30506605322320039",
    "group": "metallica"
   },
   {
    "sku": "P26S14",
    "name": "one",
    "id": "30506605372320034",
    "group": "metallica"
   },
   {
    "sku": "P26S15",
    "name": "sadbuttrue",
    "id": "30506605105653394",
    "group": "metallica"
   },
   {
    "sku": "P26S16",
    "name": "seekanddestroy",
    "id": "30506605965653308",
    "group": "metallica"
   },
   {
    "sku": "P26S17",
    "name": "theunforgiven",
    "id": "30506605235653381",
    "group": "metallica"
   }
  ]
 }
}
"""#,
        #"""
{
 "schema": 1,
 "id": "superhot",
 "title": "SUPERHOT VR",
 "package": "unity.SUPERHOT_Team.SUPERHOT_VR_QA",
 "versionName": "1.161",
 "versionCode": 161,
 "appId": "1921533091289407",
 "target": "superhot",
 "files": [
  {
   "name": "shvr_quest_161RC_signed.apk",
   "role": "apk",
   "id": "24922928844056506",
   "size": 557770041,
   "sha256": "f6892a8b6a2ab0db8b579a66b79f998124f88985424d20723f6b098afdc8c1b6",
   "required": true,
   "dest": "meta"
  }
 ],
 "origin": "avp-play recipes/store-1921533091289407.json @ 22c8fe2 (MIT, github.com/myMartek/avp-play)"
}
"""#,
        #"""
{
 "schema": 1,
 "id": "steamlink-vr",
 "title": "Steam Link",
 "package": "com.valvesoftware.steamlinkvr",
 "versionName": "2.0.23",
 "versionCode": 5002363,
 "appId": "5841245619310585",
 "target": "steamlink-vr",
 "files": [
  {
   "name": "android-steamlinkvr-release.apk",
   "role": "apk",
   "id": "27324564847218685",
   "size": 41350487,
   "sha256": "36b21974db9f5cd9f54cdf850565b80d31c76a2dd7608406fe160e3005d976d6",
   "required": true,
   "dest": "meta"
  }
 ],
 "origin": "avp-play recipes/store-5841245619310585.json @ 22c8fe2 (MIT, github.com/myMartek/avp-play)"
}
"""#,
        #"""
{
 "schema": 1,
 "id": "batman",
 "title": "Batman: Arkham Shadow",
 "package": "com.camouflaj.manta",
 "versionName": "1.4.1-350961",
 "versionCode": 350961,
 "appId": "3551691271620960",
 "target": "batman",
 "files": [
  {
   "name": "Manta_ReleaseMaster_CL423077_379.apk",
   "role": "apk",
   "id": "24544647911898657",
   "size": 75788054,
   "sha256": "1e72fe5435f336326f49f4d04cb99a5e85754eb6de3d471e692e9fef5108f309",
   "required": true,
   "dest": "meta"
  },
  {
   "name": "Audio_NonVO.obb",
   "role": "audio",
   "id": "24544643085232473",
   "size": 3457102642,
   "sha256": "85ecfc3c15c252e437efcf810310c534a6ddcb6c40394d252e8eb305db37d6e6",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "Audio_de-DE.obb",
   "role": "audio-locale",
   "id": "24544641621899286",
   "size": 1448858236,
   "sha256": "856df52af54c3253a606f2b5b292cd11fd4cfc63ab039e71fc8d53de2533402e",
   "required": false,
   "dest": "android-files/obb",
   "locale": "de-DE"
  },
  {
   "name": "Audio_en-US.obb",
   "role": "audio-locale",
   "id": "24544641108566004",
   "size": 1249987099,
   "sha256": "7e6fefb2c210d933edca6675580b25af5d8783c683273e7deb78ff28c6816057",
   "required": false,
   "dest": "android-files/obb",
   "locale": "en-US"
  },
  {
   "name": "Audio_es-ES.obb",
   "role": "audio-locale",
   "id": "24544641508565964",
   "size": 1343813242,
   "sha256": "5452249e33323bbd6d94841d0c122786e6d461cf43de726e0fd3ffe53777fcbf",
   "required": false,
   "dest": "android-files/obb",
   "locale": "es-ES"
  },
  {
   "name": "Audio_es-419.obb",
   "role": "audio-locale",
   "id": "24544641711899277",
   "size": 1407048947,
   "sha256": "09d1099933a0dd445fae2e5184e7c7a0a1f6b43a537673e07be3e481e4d697be",
   "required": false,
   "dest": "android-files/obb",
   "locale": "es-419"
  },
  {
   "name": "Audio_fr-FR.obb",
   "role": "audio-locale",
   "id": "24544641591899289",
   "size": 1257389086,
   "sha256": "b7579a84ac746cc950b306c90d2615b32a67d71ab9465c3ce9791b60ca894d6b",
   "required": false,
   "dest": "android-files/obb",
   "locale": "fr-FR"
  },
  {
   "name": "Audio_it-IT.obb",
   "role": "audio-locale",
   "id": "24544641938565921",
   "size": 1418577351,
   "sha256": "fbf5431d5bee64b37374d3a2eaa4056a744545b420b24bcdbea329b51b447ed9",
   "required": false,
   "dest": "android-files/obb",
   "locale": "it-IT"
  },
  {
   "name": "Audio_ja-JP.obb",
   "role": "audio-locale",
   "id": "24544641635232618",
   "size": 1391060721,
   "sha256": "043b59257019eaf1542e121764aa61d93605fd97061545533e51c60b8d0f952c",
   "required": false,
   "dest": "android-files/obb",
   "locale": "ja-JP"
  },
  {
   "name": "Audio_ko-KR.obb",
   "role": "audio-locale",
   "id": "24544641365232645",
   "size": 1272413266,
   "sha256": "00eee2e8a53c5c2f1e215e6690180f598f4b8a46a418411120a87f9f9fe33a4d",
   "required": false,
   "dest": "android-files/obb",
   "locale": "ko-KR"
  },
  {
   "name": "DRM1.mp4",
   "role": "video",
   "id": "24544641561899292",
   "size": 21205503,
   "sha256": "5be1618b5c6396e57d52d4ebdf208f39dbaeb96fb419c1158c54fa2117c8eafc",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "DRM2.mp4",
   "role": "video",
   "id": "24544641695232612",
   "size": 19561339,
   "sha256": "72e6d5cd71cfa9d7ec6e5d676f25bc72090a7b80d9bb85c0d7652c7530388461",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "DRM3.mp4",
   "role": "video",
   "id": "24544638945232887",
   "size": 422677813,
   "sha256": "8dbea77bc92fac6f77493fbc88835ff97f8bf858dbb88f17e06fcaf2cee13c65",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "DRM4.mp4",
   "role": "video",
   "id": "24544641705232611",
   "size": 33243662,
   "sha256": "06d87ed77fbb05f5e61c512c30109ff710af72b1c2b96aaf706943dcdebb7b36",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "DRM5A.mp4",
   "role": "video",
   "id": "24544641441899304",
   "size": 22336948,
   "sha256": "8c0a28977146536700ff71a0711edf7c8e55f055462918e0a6605ef00a7bf824",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "DRM5B.mp4",
   "role": "video",
   "id": "24544641041899344",
   "size": 51383772,
   "sha256": "d35f96713b139e466ee917d7746a7021033dacc07e5304e2c6ff86db252da29b",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "DRM5C.mp4",
   "role": "video",
   "id": "24544641615232620",
   "size": 19343606,
   "sha256": "61385ffd6b4c670f788ef3591bed590e8047a30e1e4e4ef79be3d02c07351519",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "DRM6.mp4",
   "role": "video",
   "id": "24544641065232675",
   "size": 41314206,
   "sha256": "cff219ae56b1506c6cfccc210be2b79c1985463e73192f72aa97f3ee97bbe3b6",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "DRM7.mp4",
   "role": "video",
   "id": "24544641295232652",
   "size": 35232504,
   "sha256": "373043bcd69c66b88d4d43414289626409566127e536ab4268098d5e3a2d5539",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "GothamToBlackgate.mp4",
   "role": "video",
   "id": "24544640685232713",
   "size": 202989826,
   "sha256": "c7f1b57796d3998ecf43c0692981c4438d5526039b185692641224b17aa4aee0",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "a07ad8e30364692ebad1c71ad2af6b08_monoscripts.bundle",
   "role": "content-bundle",
   "id": "24544642288565886",
   "size": 97137,
   "sha256": "332f5afb0dc765cbd027d42fef18f979a2daaf3e73eedc458cd6b8fc6a912053",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "a07ad8e30364692ebad1c71ad2af6b08_unitybuiltinshaders.bundle",
   "role": "content-bundle",
   "id": "24544644515232330",
   "size": 143449,
   "sha256": "f5f96bd2578b436837cacdcc6dad325b77e79096a9669ba5301e73925b4021c7",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "application_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641725232609",
   "size": 8318423,
   "sha256": "c1119567cd3d3f984cff9881ada896da59d6012dc8dc96edec62534d57e148d0",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "character_profiles_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642048565910",
   "size": 4245,
   "sha256": "8419e18a79828acdd2385eeb34621a99c79c8d067a9aa20e1548dad056a13ae9",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "characterviewerandgameover_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544640131899435",
   "size": 312895984,
   "sha256": "b0ed6bbb6d31ef5ad766f04451fb68b4e48158ddd6f2893321f3061ee6830f46",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "data_missionsandobjectives_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642561899192",
   "size": 85536,
   "sha256": "d6d5cbd3acc87137d91254a5fb39960b8a12faa52206d87d238c42dcddd265b9",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "data_visiblesets_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642025232579",
   "size": 126551,
   "sha256": "d7eb7d7ba00f5fa97d86347de687583694955d522d96aadb4acb5ac693510411",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "debug_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642211899227",
   "size": 40088,
   "sha256": "4ee267fff02b3570bab3e78dc4cf47c87fccf0b07c641f99670d9b814f4d8f7c",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "defaultlocalgroup_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641188565996",
   "size": 123105704,
   "sha256": "8f5f2cbd35c10ac2041df2863a039685a70b6824c8ac49e2c0c1d81ee56e2430",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "duplicateassetisolation_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642975232484",
   "size": 3691968888,
   "sha256": "012ce5e1413da15f6cf8795c609d7bafeddaaeebacdda87dbfb678293fbf95d3",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "evidence_collections_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642185232563",
   "size": 7123,
   "sha256": "46ed0de98937611dcc2b199ae5d73e575a08d6b40d116dff242b9b432c0e4b30",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "face_animations_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544640548566060",
   "size": 304212634,
   "sha256": "48fa7cf3c08de1b3e03355403f2ca9488b7cd8362b2629a5d81da11bbc22fd24",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "haptics_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642111899237",
   "size": 437651,
   "sha256": "54985b78cba28b26daa1562873bebf3b74e8ff28bddb14ce3085d41d7eeff102",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "idle_animation_sets_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641118566003",
   "size": 73732102,
   "sha256": "cf493a2122e10c8c9ad6108d08c99584e003a528a03bc81343cf9de68c3c192c",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-asset-tables-english(unitedstates)(en-us)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642558565859",
   "size": 2914,
   "sha256": "501467bcdc58daa090f2ab7d37cc3de8461a850b91c9e945db56d46b08053dbe",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-asset-tables-french(france)(fr-fr)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642481899200",
   "size": 2886,
   "sha256": "df4ea961cb8b4cc17b106893416442d221acbcf7359bebedcd3cb19b44087449",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-asset-tables-german(germany)(de-de)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642591899189",
   "size": 2886,
   "sha256": "caa8221ec18b713fb3e48cc31fcc449375a1dd1bda850d400c6583d0ce5a6ae9",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-asset-tables-italian(italy)(it-it)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642098565905",
   "size": 2953,
   "sha256": "071bad894b46346f013934eff0c064d51955e56666e5caeada257462dde58231",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-asset-tables-japanese(japan)(ja-jp)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642475232534",
   "size": 2910,
   "sha256": "c2a6265367b466eca8812d97b62b97da1927f8b42660c044b2d3fd0fb7bba246",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-asset-tables-korean(southkorea)(ko-kr)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642411899207",
   "size": 2886,
   "sha256": "f7a1fe5b984ab2348174aaaac0f3898c8ef5994f84e3b53bacfc47c2ddf87fcb",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-asset-tables-spanish(latam)(es-419)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642158565899",
   "size": 2955,
   "sha256": "6338f529bd15ec522dbe875faa4e0a88b004294ccaaaf043810cd862f6ec0a64",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-asset-tables-spanish(spain)(es-es)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642221899226",
   "size": 2954,
   "sha256": "d771cee61008f6925395a7a52a528ecec87cbaa2c4d603d667e804b0595771d9",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-assets-french(france)(fr-fr)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642028565912",
   "size": 245537,
   "sha256": "bbeaabb47730448c6b09b524e3fde4096ceab81232976d779ec18c8f3b5d1965",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-assets-japanese(japan)(ja-jp)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641855232596",
   "size": 248251,
   "sha256": "d4728672513cba567f22eb650df7a1f2324a0484f6480cef71f52b47e9b4ae50",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-assets-shared_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642001899248",
   "size": 705213,
   "sha256": "2765652b61acfe2dc66139e791a8498a204714a26002f1cf25a0f4776605805f",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-locales_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642581899190",
   "size": 2609,
   "sha256": "6825a99cf7d9729bacec055b70072519813c9c493d6dab28850f9cc4399d23f9",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-string-tables-english(unitedstates)(en-us)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641931899255",
   "size": 548002,
   "sha256": "73be1c7fb5003304988a35e114f1188abfac1a3afc46e6c6b1da11dc503ed478",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-string-tables-french(france)(fr-fr)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641928565922",
   "size": 602979,
   "sha256": "c930b6a1de7c9b47b633119deb6b14e1fd75b8806c53d90c3f42a490b9244ade",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-string-tables-german(germany)(de-de)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641865232595",
   "size": 611378,
   "sha256": "19ad9e603ea635ff6d8f8c6a73c57109585ce000c26e0223b1a9941cdaba4b12",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-string-tables-italian(italy)(it-it)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641885232593",
   "size": 588538,
   "sha256": "71b0f8a0dc930cd4922b2c25021fe0c82eaa2015a441082ba63e124f1ae4cf0f",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-string-tables-japanese(japan)(ja-jp)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641731899275",
   "size": 609515,
   "sha256": "96f6157ad62f5ae36ecb7446b9c086546cd6a7aa270848d768e095be3388a67c",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-string-tables-korean(southkorea)(ko-kr)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641858565929",
   "size": 615874,
   "sha256": "c85dcabc787d3d702df33685338753c05ce346170466d2c138acc9b3e4d1b55a",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-string-tables-spanish(latam)(es-419)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641771899271",
   "size": 583664,
   "sha256": "072d7fdbeb1ec54b02acd1a5b0699a7f419c4b56f5dfb5d1e8bb928aa9832c80",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localization-string-tables-spanish(spain)(es-es)_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641831899265",
   "size": 590664,
   "sha256": "37b14431aef3ed75db845c84bffe7f0baf77e8cbf759d156f45f458d44d738ca",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "localized-asset-manifest.txt",
   "role": "manifest",
   "id": "24544642445232537",
   "size": 266,
   "sha256": "e5b4aeeb1cef882804b1d71c0bbcb1c397c5778721828f0261bf67ddb95520fa",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "main.350961.com.camouflaj.manta.obb",
   "role": "main-obb",
   "id": "24544645935232188",
   "size": 626267749,
   "sha256": "fbcaae1fe09bd33f58901ec768ff30c066215764dc1001311559611906528b2d",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "mapdata_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641898565925",
   "size": 424596,
   "sha256": "360baefefab6006eb919884099e92d222bf7a7451752cdff17933ac632cf06eb",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "menus_general_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641701899278",
   "size": 3688045,
   "sha256": "878410959e65b6842fae437e95edca66dbcebba8e7cdfdf791b582aba9957384",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "objectpoolingconfig_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641678565947",
   "size": 14760106,
   "sha256": "e622afeb59d4ed440ae7f97d182f3e52ef90431f44fcaee2f857dbd9102182d9",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "physicmaterials_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642578565857",
   "size": 5156,
   "sha256": "5470d81713afd93d4e526c1696533181f48086d90c5ea41e1818adcd5e24afa1",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "prefabs_aicontrollers_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641688565946",
   "size": 8947206,
   "sha256": "3f91ce1e5d8e61aae4c46d40f27e2dee59ea54b282e1da58b18eefcc9ad1dd4b",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "prefabs_aipawns_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641848565930",
   "size": 181164,
   "sha256": "7d5c5f9c9ab4f5113138052ba334a6a2084800eeb53f614cb7652a32e6f29bb2",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "prefabs_characters_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641135232668",
   "size": 65639746,
   "sha256": "0ad3bd00ca4974b839840eb970872b11c79659b782021edd05b8522e1a17764b",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "prefabs_playerpawns_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544640758566039",
   "size": 187386965,
   "sha256": "5467b879ffa669847075cf5ea803ec018e61eaa7f8337d27cf06df416167e59d",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "prefabs_weapons_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641845232597",
   "size": 263793,
   "sha256": "590529ef3744e46e973c40dfcdc4609a797ba1ab24be692deb3607e1114be4bd",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_adm_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544641608565954",
   "size": 25187290,
   "sha256": "7b609f93aff8bba51c374bcbc9a34eef245129709df9bb91c938caa9543c3621",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_appflow_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544641511899297",
   "size": 34043727,
   "sha256": "90141f9cc96f6789af52348351d0ae095e4ddcf475ea71b63298c6cbee6f147c",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_aw_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544640968566018",
   "size": 1209418600,
   "sha256": "9e4948d56125a625ef4047cf06843be1a94bd96e102c4e06ef7eaf669fd07b8b",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_bat_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544640188566096",
   "size": 351700193,
   "sha256": "513177203fbcfabf7163e14df911ff8f9eefa0a629945f65fdbd90dd9b91bbc8",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_blg_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544640945232687",
   "size": 68303505,
   "sha256": "e8945d49e34bc6fe22fc939d5670fd2756f3095ab82275d303cfb9f99cd499d0",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_charview_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544641941899254",
   "size": 2702768,
   "sha256": "e50a66d76cf3154fdfb903cd8b0a6b2b43bcf6330d97edd72bd02f8e4cfc358e",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_gdn_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642551899193",
   "size": 1692,
   "sha256": "b3275c2a19e3982a7d6f7cef1d37cd940d8f8648ff2a7a06d96b6bbe19f8f099",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_gdn_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544641218565993",
   "size": 172680069,
   "sha256": "5acb5d9e3b927936e800194d8e632c29cd29c6cfc55b91e3fa1c61c169329e72",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_gen_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544640711899377",
   "size": 985743136,
   "sha256": "3d64feb7d74561c0866085c272a88317c2d096a9aee19a773fa28f875a003d6c",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_gtm_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642545232527",
   "size": 1792,
   "sha256": "21355a8ed2de9246b704984638706403e4f8c1cb2bd90dac130c9fc5c8662725",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_gtm_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544642438565871",
   "size": 2035146873,
   "sha256": "a395a9142967011f4b2e2e2d1c0d7430e91932f5d957ca72a566580463324d54",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_gut_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544640861899362",
   "size": 193395487,
   "sha256": "5d1bbf7541cc4c3be788ff0512777b7014ab4a12fb12f2b3cde07cf6ed081395",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_lfk_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544640975232684",
   "size": 75155179,
   "sha256": "430226594dcdfa040e36282fb0a9933a8ef8242ca6af9d00a6fd46236359f368",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_max_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642248565890",
   "size": 4543,
   "sha256": "91c8e8f6f75db6dd187eb9a632b924d359d687b9d06ca0b65052d08e0ff3ec05",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_max_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544639865232795",
   "size": 672433828,
   "sha256": "a25120f29ad1d9d17b39338621d6aa004ec8fc18b16c83fc41ce8e0b07e04a5e",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_row_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642178565897",
   "size": 3977,
   "sha256": "d4046b709c61c96700d2725c989e054e7ff5260b9abac4cdccdd0ea359021b2d",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_row_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544639878566127",
   "size": 672987126,
   "sha256": "afdf8e0d87304a8b17ae66887635595ec9a7a6038fc822b7014813b5a397fc8d",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_shp_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544640555232726",
   "size": 965123845,
   "sha256": "598413a410ebdaaa0fd236e1c1dd9b6316705b9374b259fd55d65fd7f6e025d7",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_sim_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544638918566223",
   "size": 388946727,
   "sha256": "a51acb2c2796f9a6f1bca39fa50c7d2090d3cd85de8eae304f142489cd162a62",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "scenes_yrd_scenes_all.bundle",
   "role": "content-bundle",
   "id": "24544640791899369",
   "size": 280411100,
   "sha256": "6722da0a70b71661f24d40848f310a33fa05efe7ec4fce288e88487a89916a9c",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "shaders_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641375232644",
   "size": 24001062,
   "sha256": "2049e93fa7421a047f607ad8aacbad409d63b98826ca85bba8996889c05d8410",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "throughlinedatabases_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641965232585",
   "size": 1408440,
   "sha256": "62c6d9dd98546afaa084ad57441a84820d96e745d8bf56204ae8f2cc0a9eedcf",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "turn_animation_sets_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642095232572",
   "size": 332865,
   "sha256": "3ba9697b4d79e95925e402bf1bc96acd8d7518e4f838ab02aa592df96713347c",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "ui_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544641741899274",
   "size": 32918373,
   "sha256": "2fd77be8f3bf4ed9f6d74c1b2e528642a00e017545f4c7de160ae96e9bacd37e",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "uitutorialvideos_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544640675232714",
   "size": 240175374,
   "sha256": "201c5d12010b7c2c04676ac27e8883249295711c7378e8ba201770a7ce36bb56",
   "required": true,
   "dest": "android-files/obb"
  },
  {
   "name": "walk_animation_sets_assets_all.bundle",
   "role": "content-bundle",
   "id": "24544642311899217",
   "size": 2141,
   "sha256": "4b3adc18edbcedfd10e36fef2292d2ffe4eaa6c85a0827acca49e85771c930bc",
   "required": true,
   "dest": "android-files/obb"
  }
 ],
 "origin": "avp-play recipes/batman.json @ 22c8fe2 (MIT, github.com/myMartek/avp-play)"
}
"""#,
        #"""
{
 "schema": 1,
 "id": "ieytd",
 "title": "I Expect You To Die",
 "package": "com.schellgames.ieytdquest",
 "versionName": "1.2.174682",
 "versionCode": 74682,
 "appId": "1987283631365460",
 "target": "ieytd",
 "files": [
  {
   "name": "IEYTD.apk",
   "role": "apk",
   "id": "24653687737631727",
   "size": 532888801,
   "sha256": "c85d8ec6e9d99d2f6965b41c2152cfcd3a59b66dca17fc2fcbe9c588fdcb8102",
   "required": true,
   "dest": "meta"
  }
 ],
 "origin": "Meta release channel live 518833048593146 (binary 24653687737631727, md5 433a98bb3badc4cc371acfab33a78951), 2026-10-12"
}
"""#,
        #"""
{
 "schema": 1,
 "id": "ktane",
 "title": "Keep Talking and Nobody Explodes",
 "package": "com.steelcrategames.keeptalkingandnobodyexplodes",
 "versionName": "1.10.15",
 "versionCode": 87,
 "appId": "2010043642376517",
 "target": "ktane",
 "files": [
  {
   "name": "KeepTalkingandNobodyExplodes.apk",
   "role": "apk",
   "id": "25827385563548991",
   "size": 150667047,
   "sha256": "a4484afbc11133ec94850c97b0c18393f7cde332f204dfc7d7e3df3e4c457c6d",
   "required": true,
   "dest": "meta"
  }
 ],
 "origin": "Meta release channel live 799274117075141 (binary 25827385563548991, md5 8974109996cbeb9da014407982f2d7d6), 2026-10-12"
}
"""#,
        #"""
{
 "schema": 1,
 "id": "re4",
 "title": "Resident Evil 4",
 "package": "com.Armature.VR4",
 "versionName": "2.3",
 "versionCode": 203,
 "appId": "2637179839719680",
 "target": "re4",
 "files": [
  {
   "name": "VR4-Android-Shipping-arm64.apk",
   "role": "apk",
   "id": "5793258947445071",
   "size": 56831952,
   "sha256": "9738e3f7637efce22010a792878246f0138e4e914acb29c4371f3a5c1329d1e1",
   "required": true,
   "dest": "meta"
  },
  {
   "name": "main.203.com.Armature.VR4.obb",
   "role": "main-obb",
   "id": "5793247094112923",
   "size": 4278854071,
   "sha256": "424c182036e5aa09f858471fabde1221bbb943d2a27820ced99083e19ebc99dd",
   "required": true,
   "dest": "android-files/Android/obb/com.Armature.VR4"
  },
  {
   "name": "patch.203.com.Armature.VR4.obb",
   "role": "patch-obb",
   "id": "5793253277445638",
   "size": 4233911336,
   "sha256": "9dfc82ce570c4ddc8f09bae391ecb569ecee050c3ce165dab7a33795dfa5bbcf",
   "required": true,
   "dest": "android-files/Android/obb/com.Armature.VR4"
  }
 ],
 "origin": "avp-play recipes/store-2637179839719680.json (MIT, github.com/myMartek/avp-play); sizes and sha256 re-checked 2026-10-28 against the owner's Quest copy"
}
"""#,
    ]
}
