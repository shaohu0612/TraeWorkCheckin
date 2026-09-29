' ====================================================
' TraeWorkCheckin - Windows 隐形后台专属执行器
' 彻底杜绝控制台黑框闪烁，保障静默运行与原生系统通知
' ====================================================

Option Explicit

Dim ws, fso, scriptDir, cmdPath, q, comSpec, fullCmd

Set ws = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ws.CurrentDirectory = scriptDir
cmdPath = scriptDir & "\run_traework_checkin.cmd"
q = Chr(34)

comSpec = ws.ExpandEnvironmentStrings("%ComSpec%")
If Len(comSpec) = 0 Then comSpec = "cmd.exe"

' 0 = 隐藏窗口无黑框闪烁，True = 等待执行完毕保障通知安全交付与退出码回收
fullCmd = q & comSpec & q & " /c " & q & q & cmdPath & q & " --silent" & q
ws.Run fullCmd, 0, True
