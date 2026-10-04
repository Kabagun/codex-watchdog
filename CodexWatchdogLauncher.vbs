Option Explicit

' wscript.exe is a GUI-subsystem host, so no console window is created. The
' third argument to Run waits for the watchdog and preserves its exit status.
Dim arguments
Set arguments = WScript.Arguments

If arguments.Count <> 2 Then
    WScript.Quit 87
End If

Function QuoteArgument(ByVal value)
    QuoteArgument = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function

Dim shell
Dim command
Dim exitCode

Set shell = CreateObject("WScript.Shell")
command = QuoteArgument(arguments(0)) _
    & " -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden" _
    & " -ExecutionPolicy Bypass -File " & QuoteArgument(arguments(1)) _
    & " -Action Check -Json"

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
