# ember-meet · 用 Windows 自带的 SAPI(System.Speech,离线)生成模拟说话人的 WAV。不用任何云 TTS。
#   pwsh -File ember-meet/sim/make-wav.ps1 [-Out .data/ember-meet/speaker.wav] [-RepeatGapSec 4]
# 内容:一句英文;装了中文语音(如 Microsoft Huihui)再加一句中文。中间留静音,方便实时字幕断句。
# 输出 16 kHz / 16-bit / 单声道 PCM WAV(Chromium --use-file-for-fake-audio-capture 能读),写到 .data/(已 gitignore)。
param(
  [string]$Out = (Join-Path $PSScriptRoot '..\..\.data\ember-meet\speaker.wav'),
  [double]$RepeatGapSec = 4
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$EN = 'Hello everyone. I think we should move the product launch to next Friday, and keep the budget under five thousand dollars.'
$ZH = '大家好。我建议读书会改到每周三晚上，先读三体，预算控制在五百元以内。'

$dir = Split-Path -Parent $Out
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
$syn = New-Object System.Speech.Synthesis.SpeechSynthesizer
$voices = $syn.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object { $_.VoiceInfo }
$en = $voices | Where-Object { $_.Culture.Name -like 'en-*' } | Select-Object -First 1
$zh = $voices | Where-Object { $_.Culture.Name -like 'zh-*' } | Select-Object -First 1
if (-not $en) { throw 'no English SAPI voice installed' }

$pb = New-Object System.Speech.Synthesis.PromptBuilder
$pb.AppendBreak([TimeSpan]::FromSeconds(1.5))
$pb.StartVoice($en.Name); $pb.AppendText($EN); $pb.EndVoice()
$pb.AppendBreak([TimeSpan]::FromSeconds($RepeatGapSec))
$lang = 'en'
if ($zh) {
  $pb.StartVoice($zh.Name); $pb.AppendText($ZH); $pb.EndVoice()
  $pb.AppendBreak([TimeSpan]::FromSeconds($RepeatGapSec))
  $lang = 'en+zh'
}
$syn.SetOutputToWaveFile((Resolve-Path -LiteralPath $dir).Path + '\' + (Split-Path -Leaf $Out), $fmt)
$syn.Speak($pb)
$syn.SetOutputToNull()
$syn.Dispose()
$len = (Get-Item -LiteralPath $Out).Length
# 只输出元数据(文件、语言、时长),不回显句子
[pscustomobject]@{ wav = (Resolve-Path -LiteralPath $Out).Path; langs = $lang; enVoice = $en.Name; zhVoice = $(if ($zh) { $zh.Name } else { $null }); bytes = $len; seconds = [math]::Round(($len - 44) / 32000, 1) } | ConvertTo-Json -Compress
