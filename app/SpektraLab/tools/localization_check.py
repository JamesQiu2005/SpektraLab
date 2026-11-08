#!/usr/bin/env python3
"""localization_check.py -- the app's four languages, held to their rules.

    tools/localization_check.py [--sources DIR] [--catalog FILE] [--info FILE] [--list-missing] [--self-test]

The app's words are in `Resources/Localizable.xcstrings` (English is the key; `zh-Hans`,
`zh-Hant` and `ja` are its values) and reach a page through `L("...")` (`Sources/Model/Localization.swift`).
This fails, naming each line, when:

  1. **missing**      a key of the catalog (or of `InfoPlist.xcstrings`) lacks `zh-Hans`, `zh-Hant` or `ja`;
  2. **placeholders** a translation does not use the arguments its key has (`%@` in the key is one
                      argument; a translation names them `%@` in order or `%1$@`, `%2$@` by position,
                      never both ways in one sentence);
  3. **script**       a `zh-Hant` value holds a character only Simplified writes, or a `zh-Hans` value
                      one only Traditional writes (`PAIRS` below: a table of telltale characters, not
                      a dictionary); a `ja` value holds a Simplified character Japanese does not write
                      (设 for 設, 图 for 図, 胶, 冲) or an old form it no longer writes (圖, 黑, 會);
  4. **unwrapped**    a literal with a word in it is handed to something that shows it -- `DrawnText(`,
                      `Text(`, `Note(`, a `title:`/`label:`/`note:` argument, `.accessibilityLabel(`,
                      ... (`SHOWN_CALLS`, `SHOWN_LABELS`) -- without `L(`. What is never translated is
                      excepted by name: `NEVER` (a name, a format, a unit) and `NOT_PAGES` (files
                      whose words are a check's or the log's, not a page's);
  5. **uncatalogued** a key the sources look up is not in the catalog;
  6. **stale**        a key of the catalog is no literal of the sources any more (but for the keys
                      `tools/localization_exceptions.json` lists as made at run time, each with its reason).

A word with two senses in the app is two keys: `L("Level", as: "a pair")` looks up `Level {a pair}`.

As far as a script can tell: rule 4 sees a literal where it is written, so a sentence a model builds
and a page shows two calls later is held by rule 5 only once somebody has wrapped it. `--list-missing`
prints the keys rule 5 found, one a line, for translating.

`--self-test` breaks each rule once, on a catalog and a source of its own, and fails unless each
break is reported: a check that cannot fail is not a check.
"""
import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
LANGUAGES = ("zh-Hans", "zh-Hant", "ja")

# Simplified and Traditional forms of one character, where neither form is written in the other
# script. Characters both scripts use with different meanings (里 后 系 台 只 干 面 表 松 划 制 云 向 几
# 余 于 才 斗 卷 布 并 准 采 价 征 志 致 咸 板 冲 发 复 汇 获 尽 历 签 须 游 郁 愿 占 折 种 钟 注 筑 么) are left out
# on purpose: they would fail a correct Traditional sentence.
PAIRS = """
机機 这這 们們 说說 时時 为為 会會 对對 开開 关關 设設 计計 认認 证證 选選 择擇 显顯 图圖 览覽 过過 还還 进進 远遠 连連 运運
边邊 适適 导導 张張 强強 归歸 录錄 径徑 总總 户戶 护護 报報 拟擬 拥擁 据據 换換 损損 摄攝 数數 断斷 无無 旧舊 暂暫
杂雜 权權 条條 来來 构構 标標 样樣 栏欄 检檢 毕畢 气氣 没沒 浅淺 测測 浏瀏 渐漸 温溫 湿濕 滤濾 灯燈 灵靈 点點 烦煩 热熱
爱愛 状狀 独獨 现現 环環 电電 画畫 监監 盘盤 码碼 确確 离離 积積 称稱 稳穩 竞競 笔筆 简簡 类類 紧緊 红紅 级級 纯純 线線
组組 细細 终終 经經 结結 给給 绝絕 统統 继繼 续續 维維 网網 罗羅 罚罰 联聯 肤膚 脑腦 脱脫 节節 药藥 虑慮 补補 装裝 观觀
视視 觉覺 订訂 让讓 许許 论論 访訪 评評 识識 词詞 译譯 试試 话話 该該 详詳 语語 误誤 请請 读讀 调調 谁誰 谈談 负負 贝貝
财財 责責 贵貴 费費 资資 赖賴 赛賽 赞贊 赶趕 趋趨 跃躍 踪蹤 车車 转轉 轮輪 软軟 轻輕 载載 较較 辑輯 输輸 达達 迁遷 违違
迟遲 递遞 逻邏 遗遺 释釋 钥鑰 错錯 键鍵 长長 门門 闭閉 问問 间間 闲閒 队隊 阳陽 阴陰 阶階 际際 陆陸 陈陳 随隨 隐隱 难難
顶頂 项項 顺順 预預 领領 频頻 题題 颜顏 额額 风風 飞飛 饰飾 马馬 驱驅 验驗 鱼魚 鸟鳥 麦麥 黄黃 齐齊 龄齡 胶膠 纸紙 负負
冲衝 晕暈 颗顆 宽寬 齿齒 边邊 张張 传傳 储儲 库庫 导導 档檔 设設 备備 质質 击擊 触觸 镜鏡 头頭 闪閃 灯燈 帧幀
补補 偿償 档檔 圆圓 层層 属屬 岁歲 带帶 帮幫 广廣 应應 库庫 废廢 异異 弹彈 归歸 径徑 彻徹 忆憶 态態 惯慣 战戰 扩擴 扫掃
抢搶 挡擋 挂掛 捞撈 掷擲 搁擱 摆擺 撑撐 敌敵 斩斬 时時 昼晝 晒曬 术術 杀殺 极極 柜櫃 栋棟 梦夢 樱櫻 欢歡 残殘 毁毀
汉漢 沟溝 泪淚 济濟 涨漲 润潤 涩澀 渊淵 滚滾 满滿 灭滅 炉爐 烂爛 烧燒 爷爺 牵牽 犹猶 狱獄 猎獵 玛瑪 琐瑣 畅暢 疗療
痒癢 盖蓋 矿礦 砖磚 础礎 祸禍 禅禪 窍竅 窝窩 笼籠 筛篩 篮籃 粮糧 纠糾 纪紀 纲綱 纳納 纵縱 纷紛 纹紋 纺紡 绍紹 绑綁 绒絨
绕繞 绘繪 绩績 绪緒 绿綠 缓緩 编編 缘緣 缩縮 缝縫 缠纏 罢罷 翘翹 耸聳 聪聰 肃肅 肠腸 肿腫 胁脅 胜勝 腾騰 舰艦 艺藝 苏蘇
荐薦 荣榮 莲蓮 获獲 营營 萧蕭 萨薩 蓝藍 虏虜 虫蟲 蚀蝕 蛮蠻 衬襯 袭襲 规規 览覽 誉譽 讨討 训訓 记記 讲講 讽諷 诀訣 诉訴
诊診 诗詩 诚誠 诞誕 询詢 诱誘 课課 谅諒 谊誼 谋謀 谎謊 谓謂 谢謝 谣謠 谦謙 谨謹 谱譜 贡貢 败敗 账賬 货貨 贩販 贪貪 贫貧
购購 贯貫 贱賤 贴貼 贷貸 贸貿 贺賀 贼賊 赁賃 赋賦 赌賭 赏賞 赐賜 赔賠 赚賺 赠贈 跷蹺 践踐 踊踴 轨軌 轩軒 轰轟 轴軸 辅輔
辆輛 辈輩 辉輝 辞辭 辩辯 迈邁 逊遜 遥遙 邓鄧 邮郵 邻鄰 郑鄭 酱醬 酿釀 针針 钉釘 钓釣 钙鈣 钝鈍 钞鈔 钢鋼 钦欽 钩鉤 钱錢
钻鑽 铁鐵 铃鈴 铅鉛 铜銅 铝鋁 银銀 铸鑄 铺鋪 链鏈 销銷 锁鎖 锅鍋 锐銳 锡錫 锤錘 锦錦 镀鍍 镇鎮 闯闖 闷悶 闸閘 闹鬧 阁閣
阅閱 阔闊 阵陣 险險 陕陝 隶隸 雾霧 韩韓 页頁 顷頃 顽頑 顾顧 顿頓 颁頒 颂頌 颇頗 颈頸 颖穎 颠顛 飘飄 饥飢 饭飯 饮飲 饱飽
饼餅 饿餓 馆館 驰馳 驳駁 驶駛 驻駐 驾駕 骂罵 骄驕 骑騎 骗騙 骤驟 鸡雞 鸣鳴 鸭鴨 鸿鴻 鹅鵝 鹰鷹 龙龍 龟龜 么麼 个個 仅僅
从從 众眾 优優 伤傷 体體 侧側 俩倆 债債 倾傾 偿償 儿兒 兰蘭 关關 兴興 养養 写寫 军軍 农農 冯馮 决決 况況 冻凍 净淨 凉涼
减減 凤鳳 击擊 凿鑿 刘劉 则則 刚剛 创創 删刪 别別 剧劇 剂劑 剑劍 劝勸 办辦 务務 动動 励勵 劲勁 劳勞 势勢 匀勻 区區 医醫
华華 协協 单單 卖賣 卢盧 卫衛 却卻 厂廠 厅廳 厉厲 压壓 厌厭 厕廁 县縣 参參 双雙 变變 叙敘 号號 叹嘆 吓嚇 吕呂 吗嗎
员員 呜嗚 咏詠 响響 哑啞 唤喚 啸嘯 喷噴 嘱囑 团團 园園 围圍 国國 圣聖 场場 坏壞 块塊 坚堅 坛壇 坝壩 坟墳 垒壘 垦墾 垫墊
堕墮 墙牆 壮壯 声聲 壳殼 处處 备備 头頭 夹夾 夺奪 奋奮 奖獎 妆妝 妇婦 妈媽 娱娛 婴嬰 孙孫 学學 宁寧 宝寶 实實 宠寵 审審
宪憲 宫宮 宾賓 寝寢 对對 寻尋 导導 寿壽 将將 尔爾 尘塵 尝嘗 层層 屉屜 届屆 属屬 岁歲 岛島 岭嶺 峡峽 币幣 师師 帅帥 帐帳
帜幟 带帶 帮幫 干幹 庄莊 庆慶 庐廬 库庫 应應 庙廟 废廢 开開 异異 弃棄 张張 弥彌 弯彎 弹彈 强強 归歸 彦彥 彻徹 忆憶 忧憂
怀懷 态態 总總 恋戀 恳懇 恶惡 悦悅 悬懸 惊驚 惧懼 惨慘 惩懲 惫憊 愤憤 愿願 慑懾 懒懶 戏戲 战戰 户戶 扑撲 执執 扩擴 扫掃
扬揚 扰擾 抚撫 抛拋 抢搶 护護 报報 拟擬 拢攏 拣揀 拥擁 拦攔 拧擰 拨撥 择擇 挚摯 挛攣 挠撓 挡擋 挣掙 挤擠 挥揮 捞撈 损損
捡撿 换換 捣搗 据據 掳擄 掷擲 掸撣 掺摻 揽攬 搀攙 摄攝 摆擺 摇搖 摊攤 撑撐 撵攆 撷擷 敌敵 敛斂 数數 斋齋 斗鬥 斩斬 断斷
""".split()
NOT_BOTH = set("干斗冲获愿么弥")  # ambiguous after all: both scripts write them
SIMPLIFIED_ONLY = {p[0] for p in PAIRS if len(p) == 2 and p[0] != p[1]} - NOT_BOTH
TRADITIONAL_ONLY = {p[1] for p in PAIRS if len(p) == 2 and p[0] != p[1]}
SIMPLIFIED_ONLY -= TRADITIONAL_ONLY

# Japanese (2026-10-22). Of the Simplified-only characters above, those modern Japanese writes too, as
# its own form (写 区 会 号 学 数 点 画 黄 ...) or as another word (机 a desk, 虫, 遥): a `ja` value may
# hold them. Every other one is a telltale of Simplified Chinese in a Japanese sentence.
JA_WRITES = set("会体写区医励却参双叙号嘱国堕壮声学宝寝寿将届属峡彦径恋悦惨据数断旧昼机条来残没浅温湿灯炉点状独画"
                "禅称脱虫蛮装触誉遥麦黄辞踊")
# Simplified that the table leaves out because Traditional writes it too, and Japanese does not
# (冲 for 現像's 沖洗, 获, 愿, 么, 后, 种, 专: l10n-ja/STYLE.md §1); and old forms (旧字体) a modern Japanese interface never writes, its
# own being the shorter one beside each (圖図 黑黒 會会 ...). A list of telltales, not a dictionary.
JA_ALSO_NOT = set("冲获愿么后种专")
KYUJITAI = """
圖図 黑黒 會会 體体 學学 國国 來来 數数 點点 畫画 圓円 邊辺 轉転 濕湿 溫温 燈灯 錄録 號号 對対 應応 經経 檢検 驗験
縣県 區区 醫医 單単 雙双 聲声 寶宝 將将 屬属 舊旧 晝昼 條条 殘残 淺浅 爐炉 狀状 獨独 稱称 蟲虫 裝装 觸触 譽誉 麥麦
黃黄 擇択 戰戦 樂楽 實実 發発 變変 廣広 當当 綠緑 鐵鉄 價価 鹽塩 擴拡 歲歳 處処 譯訳 讀読 賣売 續続 輕軽 關関 險険
靜静 顯顕 齒歯 龍竜 龜亀 壓圧 嚴厳 劑剤 勞労 參参 圍囲 壞壊 壽寿 惡悪 圍囲 澤沢 擔担 據拠 曉暁 櫻桜 氣気 滿満 燒焼
爭争 獸獣 疊畳 盡尽 稅税 穩穏 竊窃 絲糸 繪絵 纖繊 缺欠 聽聴 肅粛 膽胆 藝芸 藏蔵 蘇蘇 衞衛 觀観 覺覚 讓譲 豐豊 賴頼
轉転 辭辞 遲遅 邊辺 醉酔 釋釈 鑄鋳 鑛鉱 錢銭 鐘鐘 隨随 隱隠 雜雑 難難 靈霊 顏顔 驛駅 髮髪 鬪闘 黨党 齊斉 廳庁 傳伝
兩両 兒児 剩剰 勵励 卽即 卷巻 嘆嘆 團団 圖図 壯壮 奧奥 孃嬢 寢寝 屆届 峽峡 帶帯 廢廃 彈弾 從従 徑径 戀恋 拜拝 搖揺
攝摂 敍叙 晉晋 暑暑 曆暦 歐欧 歸帰 殼殻 淨浄 淚涙 濟済 濱浜 瀨瀬 爲為 獻献 瓣弁 癡痴 發発 盜盗 碎砕 祕秘 稻稲 穀穀
粹粋 經経 縱縦 總総 繩縄 繼継 脫脱 臺台 與与 舊旧 莊荘 螢蛍 蠶蚕 裏裏 覽覧 謠謡 證証 譯訳 豫予 貳弐 賣売 踐践 輕軽
辨弁 遞逓 鄕郷 醫医 錄録 鎭鎮 關関 陷陥 隸隷 霸覇 頰頬 顯顕 驅駆 驗験 髓髄 鷄鶏 默黙 齡齢 歷歴 檔档
""".split()
KYUJITAI_ONLY = {p[0] for p in KYUJITAI if len(p) == 2 and p[0] != p[1]}
NOT_JAPANESE_SIMPLIFIED = (SIMPLIFIED_ONLY - JA_WRITES) | JA_ALSO_NOT
assert JA_WRITES <= SIMPLIFIED_ONLY, sorted(JA_WRITES - SIMPLIFIED_ONLY)

# What shows a string: a call whose first argument is shown, and argument labels whose value is.
SHOWN_CALLS = ("DrawnText", "Text", "Note", "SectionLabel", "Label", "Button", "row", "group", "action", "rulerRow",
               "limitRow", "accessibilityLabel", "accessibilityHint", "accessibilityValue", "alert",
               "confirmationDialog", "navigationTitle", "pickRow", "note", "chip", "header", "line", "LText",
               "MenuRow", "menuRow", "section", "caption", "field", "tab", "item", "stat", "infoRow", "TextField")
SHOWN_LABELS = ("title", "subtitle", "label", "note", "line", "detail", "message", "sub", "text", "placeholder",
                "valueText", "hint", "caption", "prompt", "back", "words", "sentence", "heading", "refusal", "notice",
                "status", "footnote", "action", "confirm", "cancel", "value", "banner", "reason")

# Never translated, wherever they are shown (LOCALIZATION.md, "What is never translated").
NEVER = {
    "SpektraLab", "CINE", "HEIF", "JPG", "JPEG", "PNG", "TIFF", "RAW", "ProRAW",
    "DNG", "HEIC", "sRGB", "Adobe RGB", "Display P3", "ProPhoto", "ProPhoto RGB", "MP", "px", "EV", "ISO", "GB", "MB", "mm",
    "spektralab.app", "CC BY-SA 4.0", "Ag", "WB", "AF", "MF", "AE", "HDR", "f/", "No.", "OK", "Aa", "Bayer",
    "English", "简体中文", "繁體中文",
}

# Files whose literals are not a page's words. Each with its reason.
NOT_PAGES = {
    "Diagnostics/": "the log: its records, its zip and its read-me are English and read by tools (tools/logs_*.py)",
    "Scheduler/": "the scheduler's refusals and job records are the log's; a page that shows one looks it up with L(shown:)",
    "Engine/SpkEngine.swift": "the engine's own errors, written to the job record",
    "App/SnapshotHarness.swift": "a check's page titles (index.json)",
    "App/DesignGallery.swift": "the drawings' board",
    "Features/Develop/DarkroomSnapshots.swift": "a check's page titles and fixtures",
    "Features/FilmEdge/FilmEdgeSnapshots.swift": "a check's page titles and fixtures",
    "Features/Pair/PairSnapshots.swift": "a check's page titles and fixtures",
    "Features/Pair/PairEntrySnapshots.swift": "a check's page titles and fixtures",
    "Services/DemoLibrary.swift": "the drawings' own library: file names and camera names, which are data",
    "FilmEdge/": "the words printed on a film's edge and the Date Back's stamp: part of the picture",
    "Model/Localization.swift": "the lookup itself",
    "Mac/Library/MacLibraryCheck.swift": "a debug build's library check: its step names go to its JSON report and the log",
    "Mac/Import/MacImportCheck.swift": "a debug build's import check: its step names go to its JSON report and the log",
    "Mac/Export/MacExportCheck.swift": "a debug build's export check: its step names go to its JSON report and the log",
    "Mac/Render/MacRenderCheck.swift": "a debug build's render-cache check: its step names go to its JSON report and the log",
    "Mac/Migration/MacCatalogCheck.swift": "a debug build's catalog check: its step names go to its JSON report and the log",
    "Mac/LightTable/MacLightTableCheck.swift": "a debug build's Light Table check: its step names go to its JSON report and the log",
    "Mac/Settings/MacSettingsCheck.swift": "a debug build's Settings check: its step names go to its JSON report and the log",
    "Mac/LibraryUI/MacClipboardCheck.swift": "a debug build's Copy and Paste Settings check: its step names go to its JSON report and the log",
    "Mac/Settings/MacSettingsCoverage.swift": "a debug build's table of the Settings items and their sections: report text",
    "Mac/Library/CatalogSourcesStore.swift": "the Mac library's data: a collection's title is a key, shown through MacWords.title",
}

# `tools/localization_exceptions.json`, each entry with its reason:
#   "unwrapped"         literals that pass a display call untranslated, one by one: "file:literal": why;
#   "made_at_run_time"  keys the catalog holds for a sentence no source writes whole -- a word made from an
#                       enum's raw value, a kind read from StockCatalog.json -- which `L(shown:)` looks up.
EXCEPTIONS_FILE = HERE / "tools" / "localization_exceptions.json"


def exceptions(kind: str) -> dict:
    return json.loads(EXCEPTIONS_FILE.read_text()).get(kind, {}) if EXCEPTIONS_FILE.exists() else {}


# ---- reading Swift ------------------------------------------------------------------------------

def scan(source: str):
    """Every string literal of a Swift source outside its comments: (start, end, pieces, interpolated).

    `pieces` is the literal's text with each interpolation as None. A literal inside another's
    interpolation (`"\\(name ?? L("This film")) is a slide"`) is reported too, after the one it is in."""
    out, i, n = [], 0, len(source)
    while i < n:
        c = source[i]
        if source.startswith("//", i):
            j = source.find("\n", i)
            i = n if j < 0 else j
        elif source.startswith("/*", i):
            j = source.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif source.startswith('"""', i):
            j = source.find('"""', i + 3)
            i = n if j < 0 else j + 3            # a multi-line literal: none of the pages' words are written so
        elif c == '"':
            inner: list = []
            end, pieces = _literal(source, i, inner)
            out.append((i, end, pieces, any(p is None for p in pieces)))
            out += inner
            i = end
        else:
            i += 1
    return out


def _literal(s: str, i: int, inner: list):
    """The literal opening at s[i] == '"': (index past its closing quote, pieces). The literals
    inside its interpolations are added to `inner`."""
    pieces, text, i = [], "", i + 1
    while i < len(s) and s[i] != '"':
        if s[i] == "\\":
            e = s[i + 1]
            if e == "(":
                depth, i = 1, i + 2
                while i < len(s) and depth:
                    if s[i] == '"':
                        deeper: list = []
                        j, p = _literal(s, i, deeper)
                        inner.append((i, j, p, any(x is None for x in p)))
                        inner += deeper
                        i = j
                        continue
                    depth += (s[i] == "(") - (s[i] == ")")
                    i += 1
                pieces += [text, None]
                text = ""
                continue
            if e == "u":
                j = s.index("}", i)
                text += chr(int(s[i + 3:j], 16))
                i = j + 1
                continue
            text += {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": "\0", "r": "\r"}.get(e, e)
            i += 2
            continue
        text += s[i]
        i += 1
    pieces.append(text)
    return i + 1, pieces


def key_of(literals) -> str:
    """The catalog key of one literal or of several joined by `+`, as `LText` makes it."""
    is_format = any(interpolated for _, _, _, interpolated in literals)
    key = ""
    for _, _, pieces, _ in literals:
        for p in pieces:
            key += "%@" if p is None else (p.replace("%", "%%") if is_format else p)
    return key


def lookups(source: str):
    """Every `L("...")` of a source: (offset, key, the literals' spans). `L(shown: x)` has no key of its own."""
    lits = sorted(scan(source))
    by_start = {a: k for k, (a, _, _, _) in enumerate(lits)}
    found = []
    for m in re.finditer(r"(?<![A-Za-z0-9_.])L\(\s*", source):
        k = by_start.get(m.end())
        if k is None:
            continue
        chain = [lits[k]]
        while True:
            nxt = k + 1
            while nxt < len(lits) and lits[nxt][0] < lits[k][1]:   # the literals inside this one's interpolations
                nxt += 1
            if nxt >= len(lits) or not re.fullmatch(r"\s*\+\s*", source[lits[k][1]:lits[nxt][0]]):
                break
            k = nxt
            chain.append(lits[k])
        key = key_of(chain)
        sense = re.match(r'\s*,\s*as:\s*"([^"\\]*)"', source[chain[-1][1]:])   # `L("Level", as: "a pair")`
        if sense:
            key += " {" + sense.group(1) + "}"
        found.append((m.start(), key, [(a, b) for a, b, _, _ in chain]))
    return found


def has_word(pieces) -> bool:
    """Whether a literal says something a person reads: two letters together, outside its arguments."""
    return re.search(r"[A-Za-z]{2,}", " ".join(p for p in pieces if p is not None)) is not None


_NEVER_WORDS = None


def only_never(pieces) -> bool:
    """Whether a literal's only words are ones never translated: "ISO ", "\\(n) GB", "SpektraLab \\(version)"."""
    global _NEVER_WORDS
    if _NEVER_WORDS is None:
        _NEVER_WORDS = re.compile("|".join(sorted((re.escape(w) for w in NEVER), key=len, reverse=True)))
    text = " ".join(p for p in pieces if p is not None)
    return re.search(r"[A-Za-z]{2,}", _NEVER_WORDS.sub(" ", text)) is None


def line_of(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


# ---- the rules ----------------------------------------------------------------------------------

def arguments_of(text: str):
    """(indices a format uses, whether it mixes `%@` and `%1$@`). `%%` is a per-cent sign."""
    used, positional, sequential, nxt = set(), False, False, 1
    for m in re.finditer(r"%(%|@|(\d+)\$@)", text):
        if m.group(1) == "%":
            continue
        if m.group(2):
            positional = True
            used.add(int(m.group(2)))
        else:
            sequential = True
            used.add(nxt)
            nxt += 1
    return used, positional and sequential


def check_catalog(path: Path, problems: list, formats: bool = True) -> dict:
    catalog = json.loads(path.read_text())
    strings = catalog.get("strings", {})
    for key, entry in strings.items():
        values = {}
        for language in LANGUAGES:
            unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
            value = unit.get("value", "")
            if not value.strip() or unit.get("state") != "translated":
                problems.append(f"missing: {path.name}: {language} of {key!r}")
                continue
            values[language] = value
        for language, value in values.items():
            if formats and "%" in key:
                want, _ = arguments_of(key)
                got, mixed = arguments_of(value)
                numbers = r"%[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h)?[dfgsuxX]"   # `%.2f`: a number `String(format:)` writes
                if re.findall(numbers, key) != re.findall(numbers, value):
                    problems.append(f"placeholders: {path.name}: {language} of {key!r} is {value!r}: its numbers "
                                    f"({', '.join(re.findall(numbers, value)) or 'none'}) are not the key's, in the key's order")
                if want and (got != want or mixed):
                    problems.append(f"placeholders: {path.name}: {language} of {key!r} is {value!r}: it uses the arguments "
                                    f"{sorted(got)}{' both by order and by position' if mixed else ''}, the key has {sorted(want)}")
            # Until 2026-10-22 the Chinese name was "Spek 相机" in both scripts and was exempted here;
            # since then the name is SpektraLab in every language, and no value is exempt.
            if language == "ja":
                for table, what in ((NOT_JAPANESE_SIMPLIFIED, "Simplified Chinese, which Japanese does not write"),
                                    (KYUJITAI_ONLY, "an old form (旧字体) modern Japanese does not write")):
                    wrong = sorted(set(value) & table)
                    if wrong:
                        problems.append(f"script: {path.name}: ja of {key!r} has {''.join(wrong)}: {what}: {value!r}")
                continue
            wrong = sorted(set(value) & (SIMPLIFIED_ONLY if language == "zh-Hant" else TRADITIONAL_ONLY))
            if wrong:
                other = "Simplified" if language == "zh-Hant" else "Traditional"
                problems.append(f"script: {path.name}: {language} of {key!r} has {''.join(wrong)}, which only {other} writes: {value!r}")
    return strings


def not_a_page(relative: str):
    for prefix, why in NOT_PAGES.items():
        if relative.startswith(prefix):
            return why
    return None


def check_sources(sources: Path, problems: list):
    """Rule 4 over every source; returns (keys looked up: where first, every literal's key)."""
    excepted = exceptions("unwrapped")
    used_exceptions = set()
    looked, literal_keys = {}, set()
    shown_call = re.compile(r"(?:\b|\.)(" + "|".join(SHOWN_CALLS) + r")\(\s*$")
    shown_label = re.compile(r"\b(" + "|".join(SHOWN_LABELS) + r")\s*:\s*$")
    for path in sorted(sources.rglob("*.swift")):
        relative = str(path.relative_to(sources))
        source = path.read_text()
        lits = scan(source)
        for a, b, pieces, interpolated in lits:
            literal_keys.add(key_of([(a, b, pieces, interpolated)]))
        wrapped = set()
        for offset, key, spans in lookups(source):
            looked.setdefault(key, f"{relative}:{line_of(source, offset)}")
            literal_keys.add(key)
            wrapped.update(a for a, _ in spans)
        if not_a_page(relative):
            continue
        for a, b, pieces, interpolated in lits:
            if a in wrapped or not has_word(pieces):
                continue
            text = "".join("\\(…)" if p is None else p for p in pieces)
            if only_never(pieces) or re.fullmatch(r"[a-z0-9]+(\.[A-Za-z0-9]+)+", text):   # a name, a unit; a queue's identifier
                continue
            before = source[max(0, a - 80):a]
            m = shown_call.search(before) or shown_label.search(before)
            if not m or re.search(r"\bB\.\w+\(\s*$", before):   # `B.note("…")`: DevelopLayout names a panel's blocks for its self-test
                continue
            name = f"{relative}:{text}"
            if name in excepted:
                used_exceptions.add(name)
                continue
            problems.append(f"unwrapped: {relative}:{line_of(source, a)}: {m.group(1)} is given {text!r} without L(")
    for name in sorted(set(excepted) - used_exceptions):
        problems.append(f"unwrapped: the exception {name!r} excepts nothing any more: take it out of {EXCEPTIONS_FILE.name}")
    return looked, literal_keys


def run(sources: Path, catalog: Path, info: Path, list_missing: bool = False) -> list:
    problems: list = []
    strings = check_catalog(catalog, problems)
    if info.exists():
        check_catalog(info, problems, formats=False)
    else:
        problems.append(f"missing: {info.name} is not there: the reasons iOS shows for the library")
    looked, literal_keys = check_sources(sources, problems)
    missing = [k for k in looked if k not in strings]
    if list_missing:
        for k in missing:
            print(json.dumps(k, ensure_ascii=False))
    for k in missing:
        problems.append(f"uncatalogued: {looked[k]}: L({k!r}) is not in {catalog.name}")
    made = exceptions("made_at_run_time") if catalog.parent == EXCEPTIONS_FILE.parent.parent / "Resources" else {}
    for k in strings:
        if k not in literal_keys and k not in made:
            problems.append(f"stale: {catalog.name}: {k!r} is no literal of the sources")
    for k in made:
        if k not in strings:
            problems.append(f"uncatalogued: {EXCEPTIONS_FILE.name}: {k!r} is said to be made at run time and is not in {catalog.name}")
        elif k in literal_keys:
            problems.append(f"stale: {EXCEPTIONS_FILE.name}: {k!r} is a literal of the sources: it needs no exception")
    return problems


# ---- the check, checked -------------------------------------------------------------------------

def self_test() -> int:
    def unit(v):
        return {"stringUnit": {"state": "translated", "value": v}}

    def entry(hans, hant, ja):
        return {"localizations": {"ja": unit(ja), "zh-Hans": unit(hans), "zh-Hant": unit(hant)}}

    good_catalog = {"sourceLanguage": "en", "version": "1.0", "strings": {
        "Settings": entry("设置", "設定", "設定"),
        # Japanese's own forms that Simplified shares (写 号 画 点 会) pass.
        "%@ of %@ frames": entry("第 %1$@ 张，共 %2$@ 张", "第 %1$@ 張，共 %2$@ 張", "%2$@枚中%1$@枚の写真、画像番号・点・会"),
        "Done": entry("完成", "完成", "完了"),
        "Shown elsewhere": entry("别处显示", "別處顯示", "別の場所に表示"),
    }}
    good_info = {"sourceLanguage": "en", "version": "1.0", "strings": {"CFBundleDisplayName": entry("显示", "顯示", "表示")}}
    good_source = ('struct Page {\n    let kept = "Shown elsewhere"   // looked up where it is shown\n'
                   '    var body: some View {\n        Text(L("Settings"))\n        Text(L("\\(a) of \\(b) frames"))\n'
                   '        Button(L("Done")) {}\n        Text("HEIF")\n        Text(L(shown: kept))\n    }\n}\n')

    def trial(name, want, catalog=None, info=None, source=None):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "Sources").mkdir()
            (d / "Sources" / "Page.swift").write_text(source or good_source)
            (d / "Localizable.xcstrings").write_text(json.dumps(catalog or good_catalog, ensure_ascii=False))
            if info is not False:
                (d / "InfoPlist.xcstrings").write_text(json.dumps(info or good_info, ensure_ascii=False))
            problems = run(d / "Sources", d / "Localizable.xcstrings", d / "InfoPlist.xcstrings")
        kinds = sorted({p.split(":", 1)[0] for p in problems})
        ok = kinds == ([want] if want else [])
        print(f"{'ok  ' if ok else 'FAIL'} {name}: " + ("; ".join(problems) if problems else "no problem reported"))
        return ok

    def broken(change):
        c = json.loads(json.dumps(good_catalog))
        change(c["strings"])
        return c

    results = [
        trial("the good catalog and source pass", None),
        trial("1 a key with no zh-Hant fails", "missing",
              catalog=broken(lambda s: s["Done"]["localizations"].pop("zh-Hant"))),
        trial("1 a value not yet marked translated fails", "missing",
              catalog=broken(lambda s: s["Done"]["localizations"]["zh-Hans"]["stringUnit"].update(state="new"))),
        trial("1 a usage description with no zh-Hans fails", "missing",
              info={"strings": {"CFBundleDisplayName": {"localizations": {"zh-Hant": unit("顯示"), "ja": unit("表示")}}}}),
        trial("1 a key with no ja fails", "missing",
              catalog=broken(lambda s: s["Done"]["localizations"].pop("ja"))),
        trial("2 a ja translation that drops an argument fails", "placeholders",
              catalog=broken(lambda s: s["%@ of %@ frames"]["localizations"]["ja"]["stringUnit"].update(value="%1$@枚"))),
        trial("2 a translation that drops an argument fails", "placeholders",
              catalog=broken(lambda s: s["%@ of %@ frames"]["localizations"]["zh-Hans"]["stringUnit"].update(value="第 %1$@ 张"))),
        trial("2 a translation that names an argument the key lacks fails", "placeholders",
              catalog=broken(lambda s: s["%@ of %@ frames"]["localizations"]["zh-Hant"]["stringUnit"].update(value="第 %1$@ 張，共 %3$@ 張"))),
        trial("2 a translation that mixes order and position fails", "placeholders",
              catalog=broken(lambda s: s["%@ of %@ frames"]["localizations"]["zh-Hant"]["stringUnit"].update(value="第 %@ 張，共 %2$@ 張"))),
        trial("2 a translation that writes a number another way fails", "placeholders",
              catalog={"strings": {**good_catalog["strings"], "Glare %.1f×": entry("眩光 %.2f×", "眩光 %.1f×", "グレア %.1f×")}},
              source=good_source.replace('Text("HEIF")', 'Text(String(format: L("Glare %.1f×"), 1.0))')),
        trial("a word with two senses is two keys, and passes", None,
              catalog={"strings": {**good_catalog["strings"], "Level": entry("水平仪", "水平儀", "水準器"), "Level {a pair}": entry("横放", "橫放", "横置き")}},
              source=good_source.replace('Text("HEIF")', 'Text(L("Level"))\n        Text(L("Level", as: "a pair"))')),
        trial("5 a sense the catalog lacks fails", "uncatalogued",
              catalog={"strings": {**good_catalog["strings"], "Level": entry("水平仪", "水平儀", "水準器")}},
              source=good_source.replace('Text("HEIF")', 'Text(L("Level"))\n        Text(L("Level", as: "a pair"))')),
        trial("3 Simplified in a zh-Hant value fails", "script",
              catalog=broken(lambda s: s["Settings"]["localizations"]["zh-Hant"]["stringUnit"].update(value="设置"))),
        trial("3 Traditional in a zh-Hans value fails", "script",
              catalog=broken(lambda s: s["Settings"]["localizations"]["zh-Hans"]["stringUnit"].update(value="設定"))),
        trial("3 Simplified in a ja value fails (设定 for 設定)", "script",
              catalog=broken(lambda s: s["Settings"]["localizations"]["ja"]["stringUnit"].update(value="设定"))),
        trial("3 Simplified that Traditional shares, in a ja value, fails (冲 for 現像)", "script",
              catalog=broken(lambda s: s["Done"]["localizations"]["ja"]["stringUnit"].update(value="冲洗完了"))),
        trial("3 a correct Japanese value with 選択・拡張・導入・頁・膠 passes (Japanese, not Traditional)", None,
              catalog=broken(lambda s: s["Done"]["localizations"]["ja"]["stringUnit"].update(value="選択・拡張・導入・頁・膠・写真・図・設定"))),
        trial("3 an old form in a ja value fails (圖 for 図)", "script",
              catalog=broken(lambda s: s["Done"]["localizations"]["ja"]["stringUnit"].update(value="圖を完了"))),
        trial("4 a literal shown without the lookup fails", "unwrapped",
              source=good_source.replace('Text("HEIF")', 'Text("Not looked up")')),
        trial("4 a labelled argument shown without the lookup fails", "unwrapped",
              source=good_source.replace('Text("HEIF")', 'Row(title: "Not looked up")')),
        trial("5 a lookup the catalog lacks fails", "uncatalogued",
              source=good_source.replace('Text("HEIF")', 'Text(L("Not in the catalog"))')),
        trial("5 a lookup written over two lines is one key, and fails when the catalog lacks it", "uncatalogued",
              source=good_source.replace('Text("HEIF")', 'Text(L("Not in "\n + "the catalog"))')),
        trial("6 a key no source writes any more fails", "stale",
              source=good_source.replace('Button(L("Done")) {}', "")),
    ]
    failed = results.count(False)
    print(f"localization_check --self-test: {len(results)} trials, {failed} failed")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sources", default=str(HERE / "Sources"))
    ap.add_argument("--catalog", default=str(HERE / "Resources" / "Localizable.xcstrings"))
    ap.add_argument("--info", default=str(HERE / "Resources" / "InfoPlist.xcstrings"))
    ap.add_argument("--list-missing", action="store_true", help="print the keys the sources look up and the catalog lacks")
    ap.add_argument("--self-test", action="store_true", help="break each rule once and see it reported")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    problems = run(Path(args.sources), Path(args.catalog), Path(args.info), args.list_missing)
    if args.list_missing:
        return 0
    for p in problems:
        print(p)
    strings = json.loads(Path(args.catalog).read_text()).get("strings", {})
    print(f"localization_check: {len(strings)} keys in four languages, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
