package updater

// NewForTest constructs an Updater with an injectable exit function for testing.
func NewForTest(currentVersion string, checker ReleaseChecker, downloader Downloader, extractor Extractor, installer Installer, item MenuItem, exitFn func(int)) *Updater {
	return newWithExit(currentVersion, checker, downloader, extractor, installer, item, exitFn)
}
