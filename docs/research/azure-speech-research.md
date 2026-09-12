# Azure AI Speech (speech-to-text) — Factual Research Report

All facts below are from `learn.microsoft.com/en-us/azure/ai-services/speech-service/*`, the
`MicrosoftDocs/azure-ai-docs` source repo, or the official Azure Retail Prices API
(`prices.azure.com`). Anything not found on those sources is flagged in the final section.

Note on naming: Microsoft has rebranded the product to **"Azure Speech in Foundry Tools"**. The docs
URL path `ai-services/speech-service/` still works; the pricing URL
`azure.microsoft.com/en-us/pricing/details/cognitive-services/speech-services/` now redirects to
`azure.microsoft.com/en-us/pricing/details/speech/`.

---

## 1) DIARIZATION

### (a) Batch transcription diarization — BOTH properties exist

Both `diarizationEnabled` (boolean) and the newer `diarization` object are live. They are **not
alternatives — the docs require both** when you have 3+ speakers.

Source: <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/batch-transcription-create>

Exact wording for `diarization` (located **inside `properties`**):

> "Indicates that the Speech service should attempt diarization analysis on the input, which is
> expected to be a mono channel that contains multiple voices. The feature isn't available with
> stereo recordings.
> Diarization is the process of separating speakers in audio data. The batch pipeline can recognize
> and separate multiple speakers on mono channel recordings.
> Specify the minimum and maximum number of people who might be speaking. You must also set the
> `diarizationEnabled` property to `true`. The transcription file contains a `speaker` entry for each
> transcribed phrase.
> You need to use this property when you expect three or more speakers. For two speakers, setting
> `diarizationEnabled` property to `true` is enough.
> The maximum number of speakers for diarization must be less than 36 and more or equal to the
> `minCount` property.
> When this property is selected, source audio length can't exceed 240 minutes per file.
> **Note**: This property is only available with Speech to text REST API version 3.1 and later. If you
> set this property with any previous version, such as version 3.0, it's ignored and only two speakers
> are identified."

Exact wording for `diarizationEnabled` (also inside `properties`):

> "Specifies that the Speech service should attempt diarization analysis on the input, which is
> expected to be a mono channel that contains two voices. The default value is `false`.
> For three or more voices you also need to use property `diarization`. Use only with Speech to text
> REST API version 3.1 and later.
> When this property is selected, source audio length can't exceed 240 minutes per file."

Key derived facts:
- Speaker count cap is **< 36** (`maxSpeakers`), stated as "must be less than 36 and more or equal to
  the `minCount` property". The overview page states the service "can identify up to 35 different
  speakers in an audio recording (if the service recognizes more than 35 speakers, it throws an
  error)" — <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-to-text>
- Diarization is **mono-only**. "The feature isn't available with stereo recordings."
- Current batch submit endpoint and API version:
  `POST https://YourResourceName.cognitiveservices.azure.com/speechtotext/transcriptions:submit?api-version=2024-11-15`
- The exact property-name spellings `minSpeakers` / `maxSpeakers`: the batch doc's prose says
  "Specify the minimum and maximum number of people" and separately references a `minCount` property,
  but the batch page **does not print a literal JSON example** of the `diarization` object. The
  **fast transcription** docs do print it literally as `{"maxSpeakers": 2, "enabled": true}` (see §4).
  See the UNCERTAIN section for how to resolve the batch-side spelling.

### (b) REAL-TIME diarization — SDK-only in practice

Real-time diarization uses `ConversationTranscriber` from the Speech SDK. Quickstart:
<https://learn.microsoft.com/en-us/azure/ai-services/speech-service/get-started-stt-diarization>

**This is the decisive quote for a Dart client.** From the REST tab of that same page:

> "The speech to text REST API for short audio doesn't support real-time diarization."

And the page's recommendation for non-SDK callers:

> "For fast transcription of audio files, consider using the fast transcription API. Fast
> transcription API supports features such as language identification and diarization."

How it works in the SDK (Python example from the same page):

```python
speech_config.set_property(
    property_id=speechsdk.PropertyId.SpeechServiceResponse_DiarizeIntermediateResults,
    value='true')
conversation_transcriber = speechsdk.transcription.ConversationTranscriber(
    speech_config=speech_config, audio_config=audio_config)
```

Speaker IDs come back as `Guest-1`, `Guest-2`, …:

> "Speakers are identified as Guest-1, Guest-2, and so on, depending on the number of speakers in the
> conversation."

> "You might see `Speaker ID=Unknown` in some of the early intermediate results when the speaker isn't
> yet identified. Without intermediate diarization results (if you don't set the
> `PropertyId.SpeechServiceResponse_DiarizeIntermediateResults` property to "true"), the speaker ID is
> always "Unknown.""

Session cap — real-time diarization is limited to **240 minutes per session** (Standard S0 only, "Not
applicable" for Free F0):
<https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-services-quotas-and-limits>

**Answer to the decisive question:** Microsoft documents real-time diarization **only** through the
Speech SDK's `ConversationTranscriber`. The only other documented raw-HTTP real-time path (the
short-audio REST API) is *explicitly stated* not to support it. Microsoft publishes **no** raw
WebSocket protocol spec (see §3), so there is no supported, documented way to reach real-time
diarization from a plain Dart client.

### (c) Conversation Transcription / multi-device — RETIRED

Source: <https://github.com/MicrosoftDocs/azure-ai-docs/blob/main/articles/ai-services/speech-service/includes/release-notes/release-notes-stt.md>
(rendered at <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/releasenotes?tabs=speech-to-text>)

Under "March 2025 release", heading **"Conversation transcription multichannel diarization (retired)"**:

> "Conversation transcription multichannel diarization was retired on March 28, 2025.
> To continue using speech to text with diarization, use the following features instead:
> - Real-time speech to text with diarization
> - Fast transcription with diarization
> - Batch transcription with diarization
> These speech to text features only support diarization for single-channel audio. Multichannel audio
> that you used with conversation transcription multichannel diarization isn't supported."

Also relevant: the standalone `multi-device-conversation.md` article no longer exists in the current
`azure-ai-docs` repo (HTTP 404 on the raw path); it survives only in the archived `azure-docs` repo
under the old `cognitive-services/Speech-Service/` path. The `meeting-transcription.md` article is
likewise 404 in the current repo.

Note the naming subtlety: what was retired is **"conversation transcription multichannel
diarization"**. The `ConversationTranscriber` *class* is alive and is the documented vehicle for
single-channel real-time diarization (§1b). Billing meters named `S1 Conversation Transcription` and
`Free Conversation Transcription` still exist in the retail price feed.

Also retired: Speech to text REST API **v3.0 and v3.1 were retired on March 31, 2026**; v3.2 is GA and
`2024-11-15` / `2025-10-15` are the current dated versions (same release-notes file).

---

## 2) PRICE

**The pricing web page could not be read as text.** `azure.microsoft.com/en-us/pricing/details/speech/`
renders its price tables via client-side JavaScript; every fetch returned only site navigation
chrome. I therefore used the **official Azure Retail Prices API** (`prices.azure.com`, a
first-party Microsoft endpoint) instead of any third-party site.

**Region:** the pricing page has a region selector whose default I could not observe (JS-rendered).
The figures below are queried explicitly per-region and **East US and West US are identical for every
speech-to-text meter.**

### Speech to text (per audio hour), East US and West US

| Meter | East US | West US | Unit |
|---|---|---|---|
| `S1 Speech To Text` (real-time / standard STT) | **$1.00** | **$1.00** | 1 Hour |
| `S1 Speech to Text Batch` | **$0.18** | **$0.18** | 1 Hour |
| `Fast Transcription Speech To Text` | **$0.36** | not returned for westus | 1 Hour |
| `Fast Transcription Promo Speech To Text` (effective 2026-09-01) | **$0.10** | — | 1 Hour |
| `Custom - Fast Transcription Speech To Text` | **$0.45** | — | 1 Hour |
| `Free Speech To Text` (F0) | **$0.00** | **$0.00** | 1 Hour |

Query used (East US):
`https://prices.azure.com/api/retail/prices?$filter=productName eq 'Azure Speech' and armRegionName eq 'eastus' and (meterName eq 'S1 Speech To Text' or meterName eq 'S1 Speech to Text Batch' or meterName eq 'Free Speech To Text')`

Raw item, verbatim:

```json
{"retailPrice":1.0,"unitPrice":1.0,"armRegionName":"eastus","location":"US East",
 "effectiveStartDate":"2018-11-01T00:00:00Z","meterName":"S1 Speech To Text",
 "productName":"Azure Speech","skuName":"S1","serviceName":"Foundry Tools",
 "unitOfMeasure":"1 Hour","type":"Consumption"}
```

**Arithmetic:** none needed. The meters are natively denominated in **1 Hour** units — the feed does
not express STT per-second or per-1000-transactions. $1.00/hour ≈ $0.0167 per audio minute for
real-time; $0.18/hour = $0.003 per audio minute for batch.

**Important caveat on the tier label:** the retail feed names these SKUs **`S1`**, not `S0`. `S0` is
the ARM *resource* SKU you select when creating the resource; `S1` is the *billing* SKU name in the
price feed. The quotas doc refers throughout to "Standard (S0)". I could not find a Microsoft page
that states the S0↔S1 mapping explicitly, so treat "$1.00/hour = the Standard pay-as-you-go rate" as
the substantive fact and the letter-number label as a naming artifact.

### Diarization / speaker recognition pricing

**Diarization is not a separately priced meter.** No meter containing "Diariz" exists in the retail
feed for East US (query returned zero such items). Diarization is a property of the STT call and is
billed at the underlying STT audio-hour rate.

**"Speaker Recognition" is a different product and IS priced separately** (it is speaker
*identification/verification* — biometric voice ID — not diarization):

| Meter | East US | Unit |
|---|---|---|
| `S1 Speaker Identification Transactions` | **$10.00** | per 1K transactions |
| `S1 Speaker Verification Transactions` | **$5.00** | per 1K transactions |
| `Free Speaker Recognition Transactions` | **$0.00** | per 1K |

Arithmetic: $10.00 per 1,000 transactions = $0.01 per identification transaction; $5.00 per 1,000 =
$0.005 per verification transaction.

### Free (F0) tier allowance — NOT OBTAINED

The F0 hours/month allowance is **not publicly listed anywhere I could read as text**. The retail API
reports the F0 meter price as $0.00 but carries no quota figure. The quotas doc defers to the pricing
page:

> "For the Free (F0) pricing tier, see the monthly allowances on the pricing page."
> — <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-services-quotas-and-limits>

…and that pricing page is the JS-rendered one I could not read. **I will not state a number.** See
UNCERTAIN section.

What the quotas doc *does* say about F0 capability limits:
- Real-time STT concurrent request limit on F0: **1**, "This limit isn't adjustable."
- Fast transcription on F0: **"Not applicable"** for max file size, max audio length, and RPM.
- Batch transcription on F0: **"Not available for F0"** for requests per minute.
- Real-time diarization max audio length on F0: **"Not applicable"**.

So F0 appears not to offer fast or batch transcription at all — only real-time with concurrency 1.

---

## 3) STREAMING PROTOCOL

### Endpoint format

The **short-audio REST** endpoint (HTTPS, not WebSocket) is documented verbatim:

> "The endpoint for the REST API for short audio has this format:
> `https://YourResourceName.cognitiveservices.azure.com/stt/speech/recognition/conversation/cognitiveservices/v1`"

> "You must append the language parameter to the URL to avoid receiving a 4xx HTTP error. For example,
> the language set to US English is:
> `https://YourResourceName.cognitiveservices.azure.com/stt/speech/recognition/conversation/cognitiveservices/v1?language=en-US`"

— <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/rest-speech-to-text-short>

### Is there a public raw WebSocket protocol spec? — NO

The current docs **confirm WebSockets are used** but never specify the protocol. The only
acknowledgement I found, on the short-audio REST page:

> "The preceding formats are supported through the REST API for short audio **and WebSockets in the
> Speech service**. The Speech SDK supports the WAV format with PCM codec as well as other formats."

— <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/rest-speech-to-text-short>

And on the recognize-speech page, referring to containers:

> "Speech containers provide websocket-based query endpoint APIs that are accessed through the Speech
> SDK and Speech CLI."

— <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-recognize-speech>

I searched `learn.microsoft.com/en-us/azure/ai-services/speech-service/*` and found **no page
documenting the raw WebSocket speech protocol** — no message framing, no `speech.config` /
`audio` / `speech.hypothesis` / `turn.start` message definitions, no `X-ConnectionId` header spec.
The service documentation index
(<https://learn.microsoft.com/en-us/azure/ai-services/speech-service/>) lists REST APIs for
speech-to-text, batch transcription, text-to-speech, custom voice, batch synthesis and batch avatar —
**no WebSocket protocol entry**.

**Conclusion, stated plainly: Microsoft does not publish a protocol specification for the raw
WebSocket speech protocol for the current Azure AI Speech service.** The documented ways to do
real-time streaming STT are the Speech SDK, the Speech CLI, and the short-audio REST API — quoting the
overview:

> "Real-time speech to text is available via the Speech SDK, the Speech CLI, and Speech to text REST
> API for short audio."
> — <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-to-text>

The `wss://<region>.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1`
form is widely used in the wild and is what the open-source JS SDK constructs, but **I could not
confirm that exact wss URL on any current official Microsoft docs page.** Do not treat it as
documented. See UNCERTAIN.

---

## 4) PLAIN DART HTTP/WS CLIENT

### Is there an official Dart SDK? — No.

The Speech SDK language list on the docs index is: **C#, C++, Go, Java, JavaScript, Objective-C and
Swift, Python**. The additional SDKs (Voice Live SDK: C#, Python, Java, JavaScript; Speech
Transcription SDK: Java, Python, and per release notes also C# and JavaScript/TypeScript) likewise
have no Dart.
— <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/>

**There is no official Dart/Flutter SDK for Azure Speech.**

### Honest assessment of the three plain-HTTP paths

**Path A — Short-audio REST (`POST .../cognitiveservices/v1`): works, but crippled.**
Genuinely plain HTTP, trivially callable from Dart's `http` package. But the doc opens with a
discouragement and a hard list of limits:

> "Use the Speech to text REST API for short audio only in cases where you can't use the Speech SDK or
> fast transcription API."

> "- Requests that use the REST API for short audio and transmit audio directly can contain no more
> than 60 seconds of audio. For pronunciation assessment, the audio duration should be no more than 30
> seconds. The input audio formats are more limited compared to the Speech SDK.
> - The REST API for short audio returns only final results. It doesn't provide partial results.
> - Speech translation isn't supported via REST API for short audio. You need to use the Speech SDK.
> - Batch transcription and custom speech aren't supported via REST API for short audio."

Plus: **no diarization** (quoted in §1b). Audio must be `WAV/PCM 256 kbps 16 kHz mono` or
`OGG/OPUS 256 kbps 16 kHz mono`. Verdict for a diarizing Dart client: **unusable**.

**Path B — Raw WebSocket: not viable.** No published protocol spec (§3). You would be
reverse-engineering the JS SDK against an undocumented, unversioned wire format with no support
contract. Not a defensible engineering choice.

**Path C — Fast Transcription REST: the right answer for Dart.** Details below.

### Fast Transcription API — full detail

Primary doc: <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/fast-transcription-create>
REST reference: <https://learn.microsoft.com/en-us/rest/api/speechtotext/transcriptions/transcribe>

**It supports diarization. Yes — confirmed in the feature matrix on that page:**

| Feature | Fast transcription (default) | LLM Speech (enhanced) | MAI-Transcribe-2 |
|---|---|---|---|
| Transcription | ✅ | ✅ | ✅ |
| Translation | ❌ | ✅ | ❌ |
| **Diarization** | **✅** | **✅** | **✅** |
| **Channel (stereo)** | **✅** | **✅** | ❌ |
| Profanity filtering | ✅ | ✅ | ✅ |
| Specify locale | ✅ | ✅ | ✅ |
| Custom prompting | ❌ | ✅ | ❌ |
| Phrase list | ✅ | ✅ | ✅ |
| Segment-level timestamps | ✅ | ✅ | ✅ |
| Word-level timestamps | ✅ | ✅ | ✅ |

**Endpoint path and method** — synchronous `multipart/form-data` POST:

```
POST https://YourResourceName.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15
```

> "Make a multipart/form-data POST request to the `transcriptions` endpoint with the audio file and the
> request body properties."

**Diarization-enabled request, verbatim from the docs:**

```bash
curl --location 'https://YourResourceName.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15' \
--header 'Content-Type: multipart/form-data' \
--header 'Ocp-Apim-Subscription-Key: YourSpeechResoureKey' \
--form 'audio=@"YourAudioFile"' \
--form 'definition="{
    "locales":["en-US"], 
    "diarization": {"maxSpeakers": 2,"enabled": true}}"'
```

> "Set the `diarization` property to recognize and separate multiple speakers in one audio channel. For
> example, specify `"diarization": {"maxSpeakers": 2, "enabled": true}`. Then the transcription file
> contains `speaker` entries for each transcribed phrase."

So the fast-transcription `diarization` object takes **`enabled`** (bool) and **`maxSpeakers`** (int).
The docs show **no `minSpeakers`** for fast transcription. Full property table:

> | `diarization` | "The diarization configuration. Diarization is the process of recognizing and
> separating multiple speakers in one audio channel. For example, specify
> `"diarization": {"maxSpeakers": 2, "enabled": true}`. Then the transcription file contains `speaker`
> entries (such as `"speaker": 0` or `"speaker": 1`) for each transcribed phrase." | Optional |

— <https://github.com/MicrosoftDocs/azure-ai-docs/blob/main/articles/ai-services/speech-service/includes/request-configuration-options.md>

Other `definition` properties (same table): `channels`, `locales`, `phraseList`, `profanityFilterMode`.

**Two ways to supply audio** (only two form parts total — `audio` and `definition`):

> "- Inline audio upload `--form 'audio=@"YourAudioFile"'`
> - Audio from a public URL `--form 'definition="{"audioUrl": "https://crbn.us/hello.wav"}"'`"
> "**Tip** For long audio files, uploading from a public URL is recommended."

**Auth:** `Ocp-Apim-Subscription-Key: <key>` header, or the recommended keyless
`Authorization: Bearer <token>` with Microsoft Entra ID.

**Response shape** — `durationMilliseconds`, `combinedPhrases[]`, and `phrases[]` where each phrase
carries `channel`, `speaker`, `offsetMilliseconds`, `durationMilliseconds`, `text`, `words[]`,
`locale`, `confidence`. Speaker numbering is **0-based** (`"speaker": 0`, `"speaker": 1`) — note this
differs from batch/real-time which use `Guest-1`-style or 1-based values. From the diarization
example:

```json
{
  "durationMilliseconds": 182439,
  "combinedPhrases": [ { "channel": 0, "text": "Good afternoon. This is Sam. ..." } ],
  "phrases": [
    { "channel": 0, "speaker": 1, "offsetMilliseconds": 960, "durationMilliseconds": 640,
      "text": "Good afternoon.",
      "words": [ {"text":"Good","offsetMilliseconds":960,"durationMilliseconds":240} ],
      "locale": "en-US", "confidence": 0.93616915 }
  ]
}
```

**Output form is display-only:**

> "Unlike the batch transcription API, fast transcription API only produces transcriptions in the
> display (not lexical) form."

**Duration limits:** < 5 hours, < 500 MB (see §5).

**Dart practicality — verdict:** Fast Transcription is genuinely Dart-friendly. It is one synchronous
`multipart/form-data` POST with two string/file parts and a JSON blob, no SDK-specific handshake, no
streaming state machine, standard bearer/key auth, and a plain JSON response. `package:http`'s
`MultipartRequest` covers it directly. **This is the recommended path** — it is also what Microsoft
itself recommends to non-SDK callers, repeatedly, including from the real-time diarization quickstart.

The real trade-off is **not latency-free**: it is file-based, not streaming. If the Dart app needs
live partial results *with speakers*, no documented non-SDK option exists.

---

## 5) LIMITS

### Short-audio REST endpoint

> "Requests that use the REST API for short audio and transmit audio directly can contain no more than
> **60 seconds of audio**. For pronunciation assessment, the audio duration should be no more than 30
> seconds."
— <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/rest-speech-to-text-short>

No file-size limit is stated (the duration cap is the binding constraint). Audio must be
WAV/PCM 256 kbps 16 kHz mono, or OGG/OPUS 256 kbps 16 kHz mono.

### Fast Transcription

> "An audio file (**less than 5 hours long and less than 500 MB in size**) in one of the formats and
> codecs supported by the batch transcription API: WAV, MP3, OPUS/OGG, FLAC, WMA, AAC, ALAW in WAV
> container, MULAW in WAV container, AMR, WebM, and SPEEX."
— <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/fast-transcription-create>

Quotas table confirms (Standard S0; all "Not applicable" for F0):

| Quota | Standard (S0) |
|---|---|
| Maximum audio input file size | < 500 MB |
| Maximum audio length | < 5 hours per file |
| Shared maximum requests per minute | 600 |

— <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-services-quotas-and-limits>

(The 5-hour limit is recent: "Fast Transcription API and LLM Speech API now support up to five hours
per audio file input" — March 2026 release notes.)

### Batch transcription

| Quota | Standard (S0) |
|---|---|
| Shared maximum requests per minute | 600 |
| **Maximum file size for audio input** | **1 GB** |
| Maximum number of blobs per container | 10,000 |
| Maximum number of files per transcription request | 1,000 |
| **Maximum audio length for transcriptions with diarization enabled** | **240 minutes per file** |

— <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-services-quotas-and-limits>

> "Fast transcription and batch transcription share the same request-rate quota of 600 requests per
> minute. Requests to either API count toward the shared limit."

Note: batch transcription has **no stated maximum audio length without diarization** — only the 1 GB
file-size cap. The 240-minute cap applies specifically when diarization is on (consistent with the
`diarization` property text in §1a).

Also, the batch doc's own steering note:

> "If you need consistent fast speed for audio files less than 2 hours long and less than 300 MB in
> size, consider using the fast transcription API instead."
— <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/batch-transcription-create>

(That 2h/300MB figure is guidance for *when to prefer* fast transcription, not fast transcription's
own limit, which is 5h/500MB.)

### Real-time

| Quota | Free (F0) | Standard (S0) |
|---|---|---|
| Concurrent request limit, base model endpoint | 1 (not adjustable) | 100 (adjustable) |
| Concurrent request limit, custom endpoint | 1 (not adjustable) | 100 (adjustable) |
| Maximum audio length for real-time diarization | Not applicable | **240 minutes per session** |

Single-shot recognition via SDK stops "until a maximum of **15 seconds** of audio is processed"
(<https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-recognize-speech>).

---

## 6) MULTI-CHANNEL

**Yes, on all three surfaces — but never combined with diarization on the same stereo audio.**

### Batch transcription — `channels` property

> | `channels` | Inside `properties` | "An array of channel numbers to process. Channels `0` and `1` are
> transcribed by default." |
— <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/batch-transcription-create>

It appears in the default response body as `"channels": [0, 1]`.

Critically, batch diarization and stereo are mutually exclusive:

> "Indicates that the Speech service should attempt diarization analysis on the input, which is
> expected to be a mono channel that contains multiple voices. **The feature isn't available with
> stereo recordings.**"

### Fast transcription — `channels` property

> | `channels` | "The list of zero-based indices of the channels to be transcribed separately. **Up to
> two channels are supported unless diarization is enabled.** By default, the fast transcription API
> merges all input channels into a single channel and then performs the transcription. If this isn't
> desirable, channels can be transcribed independently without merging.
> If you want to transcribe the channels from a stereo audio file separately, you need to specify
> `[0,1]`, `[0]`, or `[1]`. Otherwise, stereo audio is merged to mono and only a single channel is
> transcribed.
> **If the audio is stereo and diarization is enabled, then you can't set the `channels` property to
> `[0,1]`. The Speech service doesn't support diarization of multiple channels.**
> For mono audio, the `channels` property is ignored, and the audio is always transcribed as a single
> channel." | Optional |
— <https://github.com/MicrosoftDocs/azure-ai-docs/blob/main/articles/ai-services/speech-service/includes/request-configuration-options.md>

Request example:

```bash
--form 'definition="{
    "locales":["en-US"], 
    "channels": [0,1]}"'
```

Response separates per channel — `combinedPhrases` gains a `channel` key:

> "The `channel` property identifies the channel if the audio file contains multiple channels. The
> `combinedPhrases` property contains full transcriptions separate per audio channel. Look for
> `"channel": 0,"text"` and `"channel": 1,"text"` to identify the full transcriptions for each channel."

Note the MAI-Transcribe-2 model does **not** support channel/stereo (per the feature matrix in §4).

### Real-time multichannel (public preview, SDK-only)

> "Real-time multichannel transcription processes a stereo (two-channel) audio file or stream and
> returns recognition results that are tagged by channel. Use it when each channel carries a distinct
> audio source that you want to transcribe independently, such as the two sides of a customer support
> call. The Speech service transcribes up to two channels at the same time and reports the source
> channel with each recognition result."
— <https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-recognize-speech-multichannel>

Requires **Speech SDK version 1.51.0 or later** (July 2026 release notes) — i.e. SDK-only, not
reachable from Dart. Support matrix from that page:

| Feature | Supported |
|---|---|
| Diarization | ✅ |
| Custom speech | ✅ |
| Semantic segmentation | ✅ |
| TrueText | ✅ |
| Language identification | ❌ |
| Multilingual models | ❌ |
| Post-stream refinement | ❌ |
| Phrase lists | ❌ |
| Pronunciation assessment | ❌ |

> "When you combine multichannel transcription with diarization, results also include speaker IDs.
> Source-channel metadata for diarization results varies by Speech SDK."
> "Results from different channels aren't guaranteed to arrive in perfect time order, especially when
> speech overlaps across channels."

(This is the one place diarization + multichannel coexist, and it is real-time SDK-only and in
preview. It is *not* a restoration of the retired conversation-transcription multichannel diarization,
which was explicitly retired for file-based use.)

---

## UNCERTAIN / NOT PUBLICLY LISTED

1. **Free (F0) tier hours-per-month allowance — NOT OBTAINED.**
   Looked at: `azure.microsoft.com/en-us/pricing/details/cognitive-services/speech-services/`
   (redirects to `/pricing/details/speech/`) — page renders prices via client-side JavaScript, every
   fetch returned navigation chrome only. Also tried `azure.microsoft.com/api/v2/pricing/speech/…` and
   `/api/v3/pricing/speech-services/calculator/…` (both 404), and the retail prices API (reports F0 as
   $0.00 with no quota field). The quotas doc explicitly defers to the pricing page. **I am not
   stating a number.** To resolve: open the pricing page in a real browser, or check the Azure portal
   pricing blade for the Speech resource.

2. **Which region the pricing page defaults to — NOT OBSERVED.** Same JS-rendering reason. Mitigated
   by querying East US and West US explicitly from the retail API; they are identical for every STT
   meter reported.

3. **`minSpeakers` / `maxSpeakers` exact spelling for *batch* transcription — NOT CONFIRMED.**
   The batch page's prose says "Specify the minimum and maximum number of people who might be
   speaking" and separately names a **`minCount`** property ("must be less than 36 and more or equal to
   the `minCount` property"), but prints no literal JSON for the batch `diarization` object; it defers
   to the REST reference. The *fast transcription* object is confirmed literally as
   `{"maxSpeakers": 2, "enabled": true}`. **Do not assume the two objects share a schema.** To
   resolve, read <https://learn.microsoft.com/en-us/rest/api/speechtotext/transcriptions/submit>
   (the `speechtotext` REST reference), which the batch page cites for the property example — I did
   not fetch it. Per the rules, I will not guess the batch property names.

4. **The `wss://<region>.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1`
   URL — NOT CONFIRMED on official docs.** Current docs give the HTTPS short-audio form
   (`https://YourResourceName.cognitiveservices.azure.com/stt/speech/recognition/conversation/cognitiveservices/v1`)
   and acknowledge that "WebSockets in the Speech service" exist, but no official page I fetched
   prints a `wss://` STT recognition URL. Custom-endpoint deployment docs reportedly emit
   `webSocketConversation`/`webSocketInteractive` fields containing `wss://<region>…` URLs
   (`how-to-custom-speech-deploy-model`), which I did not verify directly. Treat the wss form as
   undocumented.

5. **No public raw WebSocket protocol specification exists** for the current Azure AI Speech service.
   Searched the `learn.microsoft.com/en-us/azure/ai-services/speech-service/*` tree and the service
   documentation index; the REST APIs section lists speech-to-text, batch transcription,
   text-to-speech, custom voice, batch synthesis, and batch avatar — no WebSocket protocol entry. The
   old Bing Speech "websocketprotocol" doc has no current equivalent. This is a stated absence, not a
   gap in my search confidence.

6. **S0 vs S1 SKU-name mapping — not explicitly documented.** Docs say "Standard (S0)"; the retail
   price feed says `skuName: "S1"`. No Microsoft page I found states the relationship. The price
   figures themselves are verbatim from the first-party API.

7. **`Fast Transcription Speech To Text` for West US — not returned** by my West US query (only
   `S1 Speech To Text`, `S1 Speech to Text Batch`, and `Free Speech To Text` came back). This may mean
   the meter is East-US-primary with different regional coverage, or my filter missed a variant name.
   East US is confirmed at $0.36/hour. Not asserting a West US fast-transcription price.

8. **`Fast Transcription Promo` at $0.10/hour** has `effectiveStartDate: 2026-09-01` and SKU name
   "Fast Transcription Promo". The retail feed gives no expiry date and no eligibility terms. Treat as
   promotional and non-durable; do not build cost models on it.
