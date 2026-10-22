# bili-read

给一个 B 站视频链接，在**本机离线**把它的语音全部转成文字，输出一份带元数据的 Markdown。
不上传音频、不登录账号、没有次数限制、不按次收费。

> Feed a Bilibili link, get a full transcript as Markdown — **fully offline, on your own machine**.

实测：9 分 27 秒的视频，端到端 **13 秒**出 3400+ 字逐字稿（41 段，0 段失败，识别速度约 73 倍实时）。

---

## 为什么需要它

B 站的官方字幕接口对多数视频返回空列表（`subtitle.list: []`），所以"抓字幕"这条路走不通。
本工具走的是：**取音频流 → 本地解码 → 本地语音识别**，因此对**没有字幕的视频同样有效**。

## 它不做什么

- 不下载视频画面
- 不登录、不使用 Cookie
- 不把任何内容上传到云端
- 不做 AI 总结（只负责把语音变成准确的文字，总结交给你的大模型）

## 快速开始

```bash
git clone <this-repo> && cd bili-read
chmod +x bili-read.sh

./bili-read.sh --download-model        # 首次：下载语音模型（约 240MB，只需一次）
./bili-read.sh https://b23.tv/qIWgzBn  # 之后：直接给链接
```

首次运行会自动创建 `.venv` 并安装 `sherpa-onnx`（约 12MB），之后不再联网安装。

### 其他用法

```bash
./bili-read.sh BV13cBKBhEob              # 用 BV 号
./bili-read.sh BV13cBKBhEob ~/notes      # 指定输出目录
```

输出文件名：`<BV号>_<视频标题>.md`，内容为元数据 + 完整逐字稿。

## 前置条件

| 依赖 | 说明 |
|---|---|
| **macOS** | 用 AVFoundation 解码音轨，目前只在 macOS（Apple Silicon）上验证过 |
| `swiftc` | Xcode 命令行工具：`xcode-select --install` |
| `python3` | 3.9+，系统自带即可（脚本会自动建 venv） |
| 磁盘 | 模型约 240MB + 单次音频约 4–10MB（用完即删） |

**Linux 用户**：`src/video-helper.swift` 依赖 AVFoundation，需替换成 `ffmpeg -i in.mp4 -ac 1 -ar 16000 out.wav`。欢迎 PR。

## 环境变量

| 变量 | 用途 |
|---|---|
| `BILI_MODEL_DIR` | 指定 SenseVoice 模型目录，跳过下载与自动查找 |
| `PIP_INDEX_URL` | pip 镜像地址（默认阿里云） |
| `HF_MIRROR` | 模型下载镜像（默认 `https://hf-mirror.com`） |

## 模型从哪来

使用阿里开源的 **SenseVoice**（`sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17` 的 int8 版本），
中/英/日/韩/粤语自动识别，带标点与数字规范化。

`--download-model` 会依次尝试：

1. `https://hf-mirror.com/...`（国内可达）
2. `https://huggingface.co/...`（官方源）

> 实测：`huggingface.co` 在国内多数网络下直接超时，`hf-mirror.com` 约 1 秒响应，
> 240MB 模型约 2 分钟下完（≈2MB/s）。

**VAD 模型（silero_vad.onnx）** 是另一个独立文件，体积 2.3MB，用于把长音频按静音切成段。
它的官方源在 GitHub Releases，但**国内经常整段不可达**（实测连续 3 次连接失败 / 502），
所以脚本按 `hf-mirror → onnx-community → GitHub` 的顺序回退。全部失败时会退回固定 20 秒切窗，
仍能出稿，只是段边界可能落在句子中间。

> 注意：不同版本的 silero VAD 切分粒度不同（官方 1.8MB 版切 41 段，HF 2.3MB 版切 33 段），
> 但**转写文字内容等价** —— 逐句比对差异只在同音字与虚词（`Edge` 被识别成 `edG`/`age`、
> `板块`/`版块`），没有丢句。HF 版反而更干净：不会把片尾背景音乐误转成文字。

如果本机已经装过 DeepSeek Harness 之类带 SenseVoice 的工具，脚本会**直接复用现成模型**，
不会重复下载 240MB。

## 实现要点（踩过的坑）

1. **`.m4s` 扩展名 AVFoundation 不认** —— B 站音轨是标准 fMP4，但文件名叫 `.m4s` 时
   `AVAsset` 直接报 `Cannot Open`。改名成 `.mp4` 立刻正常。字节内容完全合法，纯粹是扩展名问题。
2. **下载音频时 `User-Agent` 和 `Referer` 缺一不可** —— 只带 `Referer` 会拿到 403 HTML
   而不是音频，而且 curl 不加 `-f` 时不会报错，只会静默存下一个 146 字节的错误页。
3. **macOS 自带 bash 3.2 的 `printf` 不支持 `--`** —— `printf -- '- text'` 报 `invalid option`；
   配合 `set -e` 会让整个写文件块**静默截断**（症状：输出文件只有几百字节）。
   安全写法：`printf '%s\n' "- text"`。
4. **官方字幕列表多为空** —— 必须做"有字幕抓字幕、无字幕自己转写"的两级策略。
5. **PyPI 直连在国内常常超时**（实测 25 秒无响应，阿里云镜像 0.38 秒）—— 安装必须默认走镜像，
   否则别人第一次运行就卡死。
6. **SenseVoice 单段超过 30 秒准确率下降** —— 用 Silero VAD 按静音切段（
   `min_silence 0.6s` / `max_speech 25s`），逐段识别后拼接，这是"不漏句"的关键。
   切太碎（0.25s）会在每个词间断开、丢上下文。
7. **VAD 的 `front.samples` 已经是 -1~1 的浮点** —— 不能再当成 int16 转一次，
   否则报 `TypeError: 'float' object cannot be interpreted as an integer`。
8. **GitHub Releases 在国内不可靠** —— 同一条网络下 `huggingface.co`、`github.com/.../releases`
   都可能整段连不上，只有 `hf-mirror.com` 稳定。所以模型下载必须有多源回退。

## 验证记录

| 场景 | 结果 |
|---|---|
| 本机（已有 DSH 模型） | 566s 视频 → 13.7s，41 段，0 失败 |
| 干净副本（仅 6 个源文件，无 venv/模型） | 自动建环境 + 自动编译 + 复用已有模型，18s 跑通 |
| 模拟陌生用户（HOME 指向空目录 + 自下载模型） | 21s，33 段，0 失败，3310 字 |
| 模型自动下载 | 240MB 主模型 2 分 4 秒；VAD 2.3MB 秒下 |

## 性能（566 秒视频实测，M4 / 24GB）

| 环节 | 耗时 |
|---|---|
| 下载 4.4MB 音频 | ~3 s |
| AVFoundation 解码音轨 → 16k 单声道 WAV | 0.4 s（1491×） |
| SenseVoice int8 识别（41 段 VAD 切分） | 7.7 s（73×） |
| **端到端** | **~13 s** |

## 已知限制

- 语音识别会有同音字错误（例如「第4个」识别成「第四个」这类数字格式差异），**不做校对**
- 没有时间戳，无法点击跳回原视频位置
- 不解析画面：视频里的 PPT、图表、演示内容**完全丢失**，只听音频
- 仅支持 B 站；不处理番剧、付费课程等需要登录的内容
- 无图形界面
- 单次只处理一个视频，无批量模式

## 合规声明

本项目仅用于**个人学习、检索与无障碍用途**（例如把自己有权观看的公开课转成可搜索的文字）。
请勿用于：批量抓取他人作品、绕过平台的付费/登录限制、或将转写内容再发布。
转写结果的版权归属原视频作者，使用者自行承担合规责任。

## License

MIT — 见 [LICENSE](LICENSE)。
`src/video-helper.swift` 音轨解码器来自同一作者的 dsh-screen-reader 项目（同为 MIT）。
