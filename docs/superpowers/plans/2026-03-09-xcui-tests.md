# XCUI Tests Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a UI test target to JoyMapperSilicon and write basic XCUI tests for app launch, settings sheet, and app list.

**Architecture:** Use a Ruby script (xcodeproj gem, bundled with CocoaPods) to add a UI Testing Bundle target to the existing Xcode project. Add accessibility identifiers to key UI elements in the app code. Write XCUITest cases that verify core window structure and settings sheet behavior.

**Tech Stack:** XCTest/XCUITest, xcodeproj Ruby gem, Swift 5, AppKit

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `scripts/add_ui_test_target.rb` | Create | Ruby script to add UI test target to xcodeproj |
| `JoyMapperSiliconUITests/JoyMapperSiliconUITests.swift` | Create | Main UI test file with test cases |
| `JoyMapperSiliconUITests/Info.plist` | Create | Info.plist for UI test bundle |
| `JoyKeyMapper/Views/ViewController.swift` | Modify | Add accessibility identifiers to main UI elements |
| `JoyKeyMapper/Views/AppSettings/AppSettingsViewController.swift` | Modify | Add accessibility identifiers to settings controls |
| `JoyMapperSilicon.xcodeproj/project.pbxproj` | Modify (via script) | Add UI test target |
| `JoyMapperSilicon.xcodeproj/xcshareddata/xcschemes/JoyKeyMapper.xcscheme` | Modify | Add test target to scheme's Testables |

---

## Chunk 1: Add UI Test Target and Write Tests

### Task 1: Create the UI test Info.plist

**Files:**
- Create: `JoyMapperSiliconUITests/Info.plist`

- [ ] **Step 1: Create Info.plist for UI test bundle**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>$(PRODUCT_TYPE_FRAMEWORK_HEADER)</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
```

- [ ] **Step 2: Commit**

```bash
git add JoyMapperSiliconUITests/Info.plist
git commit -m "chore: add Info.plist for UI test target"
```

### Task 2: Add UI test target to Xcode project

**Files:**
- Create: `scripts/add_ui_test_target.rb`
- Modify: `JoyMapperSilicon.xcodeproj/project.pbxproj` (via script)

- [ ] **Step 1: Create Ruby script to add UI test target**

This script uses the `xcodeproj` gem (bundled with CocoaPods) to:
- Add a `JoyMapperSiliconUITests` UI testing bundle target
- Set it as a dependency of the main `JoyMapperSilicon` target
- Configure build settings (Swift 5, bundle identifier, Info.plist path)
- Add the test Swift file as a source

```ruby
#!/usr/bin/env ruby
require 'xcodeproj'

project_path = File.join(__dir__, '..', 'JoyMapperSilicon.xcodeproj')
project = Xcodeproj::Project.open(project_path)

# Find the main app target
app_target = project.targets.find { |t| t.name == 'JoyMapperSilicon' }
abort("Could not find JoyMapperSilicon target") unless app_target

# Check if UI test target already exists
if project.targets.any? { |t| t.name == 'JoyMapperSiliconUITests' }
  puts "UI test target already exists, skipping."
  exit 0
end

# Create UI testing bundle target
ui_test_target = project.new_target(
  :ui_test_bundle,
  'JoyMapperSiliconUITests',
  :osx
)

# Add dependency on the main app target
ui_test_target.add_dependency(app_target)

# Configure build settings for both Debug and Release
ui_test_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.elliotfiske.JoyMapperSiliconUITests'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['INFOPLIST_FILE'] = 'JoyMapperSiliconUITests/Info.plist'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['DEVELOPMENT_TEAM'] = 'CKGA64W25Z'
  config.build_settings['TEST_TARGET_NAME'] = 'JoyMapperSilicon'
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '10.14'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = [
    '$(inherited)',
    '@executable_path/../Frameworks',
    '@loader_path/../Frameworks'
  ]
end

# Add the test source file group and file reference
group = project.new_group('JoyMapperSiliconUITests', 'JoyMapperSiliconUITests')
test_file = group.new_reference('JoyMapperSiliconUITests.swift')
ui_test_target.source_build_phase.add_file_reference(test_file)

project.save
puts "Successfully added JoyMapperSiliconUITests target."
```

- [ ] **Step 2: Run the script**

Run: `ruby scripts/add_ui_test_target.rb`
Expected: "Successfully added JoyMapperSiliconUITests target."

- [ ] **Step 3: Commit**

```bash
git add scripts/add_ui_test_target.rb JoyMapperSilicon.xcodeproj/project.pbxproj
git commit -m "chore: add UI test target to Xcode project"
```

### Task 3: Update scheme to include UI test target

**Files:**
- Modify: `JoyMapperSilicon.xcodeproj/xcshareddata/xcschemes/JoyKeyMapper.xcscheme`

- [ ] **Step 1: Add TestableReference to the scheme's Testables section**

Replace the empty `<Testables>` block with one that references the new UI test target. The BlueprintIdentifier must match the UUID generated by the Ruby script — read it from the updated project.pbxproj after running the script.

In the scheme XML, replace:
```xml
      <Testables>
      </Testables>
```

With:
```xml
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "<UUID_FROM_PBXPROJ>"
               BuildableName = "JoyMapperSiliconUITests.xctest"
               BlueprintName = "JoyMapperSiliconUITests"
               ReferencedContainer = "container:JoyMapperSilicon.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
```

To find the UUID: grep for `JoyMapperSiliconUITests` in the pbxproj and find the PBXNativeTarget entry's UUID.

- [ ] **Step 2: Commit**

```bash
git add JoyMapperSilicon.xcodeproj/xcshareddata/xcschemes/JoyKeyMapper.xcscheme
git commit -m "chore: add UI test target to scheme"
```

### Task 4: Add accessibility identifiers to main UI elements

**Files:**
- Modify: `JoyKeyMapper/Views/ViewController.swift`
- Modify: `JoyKeyMapper/Views/AppSettings/AppSettingsViewController.swift`

- [ ] **Step 1: Add identifiers in ViewController.viewDidLoad()**

In `ViewController.swift`, at the end of `viewDidLoad()` (after the NotificationCenter observers, before the closing `}`), add:

```swift
        // Accessibility identifiers for UI testing
        controllerCollectionView.setAccessibilityIdentifier("controllerCollectionView")
        appTableView.setAccessibilityIdentifier("appTableView")
        configTableView.setAccessibilityIdentifier("configTableView")
        appAddRemoveButton.setAccessibilityIdentifier("appAddRemoveButton")
```

- [ ] **Step 2: Add identifiers in AppSettingsViewController.viewDidLoad()**

In `AppSettingsViewController.swift`, at the end of `viewDidLoad()`, add:

```swift
        // Accessibility identifiers for UI testing
        disconnectTime.setAccessibilityIdentifier("disconnectTime")
        notifyConnection.setAccessibilityIdentifier("notifyConnection")
        notifyBatteryLevel.setAccessibilityIdentifier("notifyBatteryLevel")
        notifyBatteryCharge.setAccessibilityIdentifier("notifyBatteryCharge")
        notifyBatteryFull.setAccessibilityIdentifier("notifyBatteryFull")
        launchOnLogin.setAccessibilityIdentifier("launchOnLogin")
```

- [ ] **Step 3: Commit**

```bash
git add JoyKeyMapper/Views/ViewController.swift JoyKeyMapper/Views/AppSettings/AppSettingsViewController.swift
git commit -m "feat: add accessibility identifiers for UI testing"
```

### Task 5: Write the UI test file

**Files:**
- Create: `JoyMapperSiliconUITests/JoyMapperSiliconUITests.swift`

- [ ] **Step 1: Write the test file**

```swift
import XCTest

final class JoyMapperSiliconUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - App Launch

    func testAppLaunches() throws {
        // The app should have at least one window after launch
        XCTAssertTrue(app.windows.count >= 1, "App should have at least one window")
    }

    func testMainWindowContainsExpectedElements() throws {
        let window = app.windows.firstMatch

        // Main UI panels should exist
        let appTable = window.tables["appTableView"]
        XCTAssertTrue(appTable.waitForExistence(timeout: 5), "App table view should exist")

        let configOutline = window.outlines["configTableView"]
        XCTAssertTrue(configOutline.exists, "Config outline view should exist")

        let addRemoveButton = window.segmentedControls["appAddRemoveButton"]
        XCTAssertTrue(addRemoveButton.exists, "Add/Remove segmented control should exist")
    }

    func testAppTableShowsDefaultRow() throws {
        let window = app.windows.firstMatch
        let appTable = window.tables["appTableView"]
        guard appTable.waitForExistence(timeout: 5) else {
            XCTFail("App table view should exist")
            return
        }

        // The first row should always be "Default"
        let defaultCell = appTable.cells.containing(.staticText, identifier: "Default").firstMatch
        XCTAssertTrue(defaultCell.exists, "Default row should always be present in app table")
    }

    // MARK: - Options / Settings Sheet

    func testOptionsButtonOpensSettingsSheet() throws {
        let window = app.windows.firstMatch

        // Find and click the Options button
        let optionsButton = window.buttons["Options"]
        guard optionsButton.waitForExistence(timeout: 5) else {
            XCTFail("Options button should exist")
            return
        }
        optionsButton.click()

        // A sheet should appear with settings controls
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Settings sheet should appear")

        // Verify key settings controls exist
        XCTAssertTrue(sheet.checkBoxes["notifyConnection"].exists, "Notify connection checkbox should exist")
        XCTAssertTrue(sheet.checkBoxes["notifyBatteryLevel"].exists, "Notify battery level checkbox should exist")
        XCTAssertTrue(sheet.checkBoxes["launchOnLogin"].exists, "Launch on login checkbox should exist")
        XCTAssertTrue(sheet.popUpButtons["disconnectTime"].exists, "Disconnect time popup should exist")
    }

    func testSettingsSheetDismissesOnOK() throws {
        let window = app.windows.firstMatch

        // Open settings
        let optionsButton = window.buttons["Options"]
        guard optionsButton.waitForExistence(timeout: 5) else {
            XCTFail("Options button should exist")
            return
        }
        optionsButton.click()

        let sheet = window.sheets.firstMatch
        guard sheet.waitForExistence(timeout: 5) else {
            XCTFail("Settings sheet should appear")
            return
        }

        // Click OK to dismiss
        let okButton = sheet.buttons["OK"]
        XCTAssertTrue(okButton.exists, "OK button should exist in settings sheet")
        okButton.click()

        // Sheet should be dismissed
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Settings sheet should be dismissed after OK")
    }
}
```

- [ ] **Step 2: Verify the project builds with tests**

Run: `xcodebuild build-for-testing -workspace JoyMapperSilicon.xcworkspace -scheme JoyKeyMapper -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run the tests**

Run: `xcodebuild test -workspace JoyMapperSilicon.xcworkspace -scheme JoyKeyMapper -destination 'platform=macOS' 2>&1 | tail -20`
Expected: Tests execute (some may fail if the app UI doesn't match expectations — that's fine, we iterate)

- [ ] **Step 4: Fix any test failures and commit**

```bash
git add JoyMapperSiliconUITests/JoyMapperSiliconUITests.swift
git commit -m "feat: add basic XCUI tests for app launch, settings sheet, and app table"
```

---

## Notes

- **No controller required**: All tests verify window/UI structure that exists regardless of whether a Joy-Con is connected.
- **waitForExistence**: Used liberally because AppKit UI elements may take a moment to appear after launch.
- **waitForNonExistence**: Available in Xcode 14.3+ (macOS 13+). If targeting older Xcode, replace with a polling loop or `XCTAssertFalse(sheet.exists)` after a brief sleep.
- **Storyboard identifiers**: The Options button is found by its title text (`"Options"`). If this doesn't work, we may need to add an accessibility identifier to it in the storyboard or programmatically in `viewDidLoad`.
- **Scheme container reference**: The existing scheme has inconsistent container references (`JoyKeyMapper.xcodeproj` vs `JoyMapperSilicon.xcodeproj`). Use `JoyMapperSilicon.xcodeproj` for the new test target reference.
