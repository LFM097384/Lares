# 推送到 GitHub(绕开本机两个坑)
#
# 坑 1:git 默认的 schannel TLS 后端在本机握手失败
#       (SEC_E_NO_CREDENTIALS),即便 TCP 到 github.com:443 是通的。
#       -> 本仓库已 git config --local http.sslBackend openssl
# 坑 2:credential.helper=store 里没有可用凭据,且 ~/.gitconfig 被锁
#       (Permission denied),gh auth setup-git 写不进去。
#       -> 这里直接从 gh CLI 取 token 走 URL 内联,用完不留痕
#         (不写进 .git/config,避免 token 落盘)
#
# 用法:pwsh scripts/push.ps1            推 main
#       pwsh scripts/push.ps1 -Ref v0.2.0   推 tag

param([string]$Ref = 'HEAD:main')

$ErrorActionPreference = 'Stop'

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) { $gh = 'D:\Programs\GitHub CLI\gh.exe' }
else { $gh = $gh.Source }
if (-not (Test-Path $gh)) { throw "找不到 gh CLI;请先装 GitHub CLI 或手动配置凭据" }

$token = & $gh auth token 2>$null
if (-not $token) { throw "gh 未登录:先跑 gh auth login" }

$env:GIT_TERMINAL_PROMPT = '0'
$url = "https://x-access-token:$token@github.com/LFM097384/Lares.git"

try {
    git -c http.sslBackend=openssl -c credential.helper= push $url $Ref
    if ($LASTEXITCODE -ne 0) { throw "push 失败(exit $LASTEXITCODE)" }
    # 同步本地远端跟踪引用,好让 git status 的 ahead/behind 准确
    git -c http.sslBackend=openssl -c credential.helper= fetch $url main 2>&1 | Out-Null
    git update-ref refs/remotes/origin/main FETCH_HEAD 2>&1 | Out-Null
    Write-Output "已推送:$Ref"
} finally {
    Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
}
