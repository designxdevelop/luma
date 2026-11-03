import LumaUI

@main enum Main {
    static func main() {
        LumaSiri.vocabularyChanged = { LumaShortcuts.updateAppShortcutParameters() }
        LumaMobileApp.main()
    }
}
