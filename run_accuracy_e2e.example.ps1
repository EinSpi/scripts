# 按实际环境修改后执行此文件，或直接向 run_accuracy_e2e.ps1 传参。
# 三并发资源映射：
#   槽位 0：卡 0/1，vLLM 8100/8101，uvicorn 8899
#   槽位 1：卡 2/3，vLLM 8102/8103，uvicorn 8900
#   槽位 2：卡 4/5，vLLM 8104/8105，uvicorn 8901
# TotalDevices 是从 FirstDevice 开始的可用卡数量，不是最大卡号。
# 后续批次继续使用 8902、8903……，不同超参组合不会复用 uvicorn 端口。
# 输出统一写入：<项目根目录>\tests\<ExperimentName>\
$sshPassword = Read-Host "请输入 root SSH 密码" -AsSecureString

# 无人值守时可以改用下一行（不要把含真实密码的文件提交到版本库）：
# $sshPassword = ConvertTo-SecureString "在这里填写root密码" -AsPlainText -Force

& "$PSScriptRoot\run_accuracy_e2e.ps1" `
    -RemoteIp "135.82.26.228" `
    -ExperimentName "exp_0729" `
    -SshUser "root" `
    -SshPassword $sshPassword `
    -Strats @("x") `
    -PruningLayers @(8, 16) `
    -PruningRates @(20, 30) `
    -FirstDevice 0 `
    -FirstPort 8100 `
    -UvicornPort 8899 `
    -MaxConcurrency 3 `
    -TotalDevices 6

# 六张空闲卡不连续时，可替换上面的 FirstDevice/TotalDevices：
# -DeviceIds @(0, 1, 3, 4, 6, 7)

# 脚本默认位于 AISF-VLM-Perception 根目录，因此通常无需传入以下路径：
# -ProjectRoot "D:\project\2026\26B\伴学评测\AISF-VLM-Perception"
# -ConfigPath ".\app\common\config.py"
# -TestPath ".\tests\modelTestV7_offline-v1.py"
