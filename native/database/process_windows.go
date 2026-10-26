package configdb

import "golang.org/x/sys/windows"

func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	process, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return err != windows.ERROR_INVALID_PARAMETER
	}
	defer windows.CloseHandle(process)
	var code uint32
	if windows.GetExitCodeProcess(process, &code) != nil {
		return true
	}
	return code == 259
}
