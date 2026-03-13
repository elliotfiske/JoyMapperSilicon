# Tuist Migration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate JoyMapperSilicon from Xcode project + CocoaPods to Tuist, vendoring the JoyConSwift dependency as a local target.

**Architecture:** Vendor JoyConSwift's 11 Swift source files into `Vendor/JoyConSwift/Sources/`. Define all three targets (JoyMapperSilicon app, JoyMapperSiliconLauncher helper, JoyConSwift library) in a single `Project.swift`. Remove CocoaPods entirely. Tuist auto-generates the Xcode project and schemes.

**Tech Stack:** Tuist 4.x, Swift 5, AppKit, Core Data, IOKit (via JoyConSwift)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Vendor/JoyConSwift/Sources/*.swift` | Create (copy from upstream) | 11 vendored Swift source files |
| `Vendor/JoyConSwift/Sources/controllers/*.swift` | Create (copy from upstream) | 6 controller subclass files |
| `Project.swift` | Create | Tuist project manifest — defines all targets, dependencies, settings |
| `Tuist/Config.swift` | Create | Tuist global configuration |
| `.gitignore` | Modify | Add Tuist-generated files, remove CocoaPods patterns |
| `Podfile` | Delete | No longer needed |
| `Podfile.lock` | Delete | No longer needed |
| `Pods/` | Delete | No longer needed |
| `JoyMapperSilicon.xcworkspace/` | Delete | Tuist generates its own workspace |
| `JoyMapperSilicon.xcodeproj/` | Delete | Tuist generates its own project |

---

## Chunk 1: Vendor JoyConSwift and Create Tuist Manifests

### Task 1: Vendor JoyConSwift source files

**Files:**
- Create: `Vendor/JoyConSwift/Sources/Controller.swift`
- Create: `Vendor/JoyConSwift/Sources/JoyCon.swift`
- Create: `Vendor/JoyConSwift/Sources/JoyConManager.swift`
- Create: `Vendor/JoyConSwift/Sources/Rumble.swift`
- Create: `Vendor/JoyConSwift/Sources/Subcommand.swift`
- Create: `Vendor/JoyConSwift/Sources/Utils.swift`
- Create: `Vendor/JoyConSwift/Sources/HomeLEDPattern.swift`
- Create: `Vendor/JoyConSwift/Sources/controllers/ProController.swift`
- Create: `Vendor/JoyConSwift/Sources/controllers/SNESController.swift`
- Create: `Vendor/JoyConSwift/Sources/controllers/FamicomController1.swift`
- Create: `Vendor/JoyConSwift/Sources/controllers/FamicomController2.swift`
- Create: `Vendor/JoyConSwift/Sources/controllers/JoyConL.swift`
- Create: `Vendor/JoyConSwift/Sources/controllers/JoyConR.swift`

- [ ] **Step 1: Clone JoyConSwift and copy source files**

```bash
git clone --depth 1 https://github.com/magicien/JoyConSwift.git /tmp/JoyConSwift 2>/dev/null || true
mkdir -p Vendor/JoyConSwift/Sources/controllers
cp /tmp/JoyConSwift/Source/*.swift Vendor/JoyConSwift/Sources/
cp /tmp/JoyConSwift/Source/controllers/*.swift Vendor/JoyConSwift/Sources/controllers/
```

Do NOT copy the `JoyConSwift.h` umbrella header or `Info.plist` — Tuist generates those for framework targets.

- [ ] **Step 2: Verify the files are present**

Run: `find Vendor/JoyConSwift/Sources -name '*.swift' | sort`
Expected: 13 Swift files (7 in Sources/, 6 in Sources/controllers/)

- [ ] **Step 3: Commit**

```bash
git add Vendor/
git commit -m "chore: vendor JoyConSwift 0.2.1 source files"
```

### Task 2: Create Tuist configuration

**Files:**
- Create: `Tuist/Config.swift`

- [ ] **Step 1: Create Tuist/Config.swift**

```swift
import ProjectDescription

let config = Config(
    compatibleXcodeVersions: .all,
    generationOptions: .options(
        optionalAuthentication: true
    )
)
```

- [ ] **Step 2: Commit**

```bash
git add Tuist/
git commit -m "chore: add Tuist config"
```

### Task 3: Create Project.swift manifest

**Files:**
- Create: `Project.swift`

This is the critical file. It must replicate the existing build settings from the pbxproj.

Key things to preserve:
- Main app bundle ID: `com.elliotfiske.JoyMapperSilicon`
- Launcher bundle ID: `cn.qibinc.JoyMapperSiliconLauncher`
- Development team: `CKGA64W25Z`
- macOS deployment target: `11.0` (from Podfile; the pbxproj said 10.14 but the Pod required 11.0)
- Hardened runtime enabled
- App sandbox + USB entitlements (main app)
- App sandbox entitlements (launcher)
- LSUIElement = true (both apps, set in Info.plist already)
- Launcher copied into `Contents/Library/LoginItems`
- "Set build number" script phase on main app
- Core Data model compiled into main app
- Localized storyboards (en, ja) and strings files

- [ ] **Step 1: Create Project.swift**

```swift
import ProjectDescription

let project = Project(
    name: "JoyMapperSilicon",
    settings: .settings(
        base: [
            "DEVELOPMENT_TEAM": "CKGA64W25Z",
            "CODE_SIGN_STYLE": "Automatic",
            "SWIFT_VERSION": "5.0",
        ],
        debug: [
            "ENABLE_TESTABILITY": "YES",
        ]
    ),
    targets: [
        // MARK: - Main App
        .target(
            name: "JoyMapperSilicon",
            destinations: [.mac],
            product: .app,
            bundleId: "com.elliotfiske.JoyMapperSilicon",
            deploymentTargets: .macOS("11.0"),
            infoPlist: .file(path: "JoyKeyMapper/Info.plist"),
            sources: ["JoyKeyMapper/**/*.swift"],
            resources: .resources(
                [
                    "JoyKeyMapper/Views/**/*.storyboard",
                    "JoyKeyMapper/Views/**/*.xib",
                    "JoyKeyMapper/Assets.xcassets",
                    "JoyKeyMapper/Misc/*.strings",
                ]
            ),
            entitlements: .file(path: "JoyKeyMapper/JoyKeyMapper.entitlements"),
            scripts: [
                .post(
                    path: "scripts/set_build_number.sh",
                    name: "Set build number"
                ),
            ],
            dependencies: [
                .target(name: "JoyConSwift"),
                .target(name: "JoyMapperSiliconLauncher"),
            ],
            settings: .settings(
                base: [
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "CURRENT_PROJECT_VERSION": "10",
                    "MARKETING_VERSION": "1.0",
                    "CODE_SIGN_ENTITLEMENTS": "JoyKeyMapper/JoyKeyMapper.entitlements",
                ],
                configurations: [
                    .debug("Debug"),
                    .release("Release"),
                ]
            ),
            coreDataModels: [
                .coreDataModel("JoyKeyMapper/DataModels/JoyKeyMapper.xcdatamodeld"),
            ]
        ),

        // MARK: - Launcher Helper
        .target(
            name: "JoyMapperSiliconLauncher",
            destinations: [.mac],
            product: .app,
            bundleId: "cn.qibinc.JoyMapperSiliconLauncher",
            deploymentTargets: .macOS("11.0"),
            infoPlist: .file(path: "JoyKeyMapperLauncher/Info.plist"),
            sources: ["JoyKeyMapperLauncher/**/*.swift"],
            resources: .resources(
                [
                    "JoyKeyMapperLauncher/**/*.storyboard",
                    "JoyKeyMapperLauncher/Assets.xcassets",
                ]
            ),
            entitlements: .file(path: "JoyKeyMapperLauncher/JoyKeyMapperLauncher.entitlements"),
            settings: .settings(
                base: [
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "SKIP_INSTALL": "YES",
                ],
                configurations: [
                    .debug("Debug"),
                    .release("Release"),
                ]
            )
        ),

        // MARK: - Vendored JoyConSwift
        .target(
            name: "JoyConSwift",
            destinations: [.mac],
            product: .framework,
            bundleId: "com.elliotfiske.JoyConSwift",
            deploymentTargets: .macOS("11.0"),
            sources: ["Vendor/JoyConSwift/Sources/**/*.swift"],
            settings: .settings(
                base: [
                    "DEFINES_MODULE": "YES",
                ]
            )
        ),
    ]
)
```

**Important notes on this manifest:**

- The launcher is declared as a dependency of the main app. Tuist handles embedding it. However, the launcher needs to go specifically into `Contents/Library/LoginItems`, not the default Frameworks location. If Tuist doesn't handle this correctly by default, we may need to add a copy files phase. We'll verify this during the build step and adjust.
- Core Data model is declared via `coreDataModels` parameter, not in `resources`.
- The "Set build number" script runs as a post-build action.
- JoyConSwift is a framework target so `import JoyConSwift` continues to work unchanged in the app code.

- [ ] **Step 2: Commit**

```bash
git add Project.swift
git commit -m "chore: add Tuist Project.swift manifest"
```

### Task 4: Update .gitignore for Tuist

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Update .gitignore**

Add Tuist-generated entries and remove CocoaPods entries. The final .gitignore should include:

```
# Tuist-generated
Derived/
*.xcodeproj
*.xcworkspace

# Xcode
DerivedData/
build/

# macOS
.DS_Store

# Context
.context/
```

Remove any existing CocoaPods-related ignore patterns (like `Pods/` if it was previously tracked, or CocoaPods patterns).

**Note:** We're gitignoring `*.xcodeproj` and `*.xcworkspace` because Tuist generates them. The project source of truth is now `Project.swift`.

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: update .gitignore for Tuist migration"
```

---

## Chunk 2: Generate, Build, and Clean Up

### Task 5: Remove CocoaPods and old Xcode project files

**Files:**
- Delete: `Podfile`
- Delete: `Podfile.lock`
- Delete: `Pods/` (entire directory)
- Delete: `JoyMapperSilicon.xcworkspace/` (entire directory)
- Delete: `JoyMapperSilicon.xcodeproj/` (entire directory)

- [ ] **Step 1: Remove CocoaPods files and old project**

```bash
rm Podfile Podfile.lock
rm -rf Pods/
rm -rf JoyMapperSilicon.xcworkspace/
rm -rf JoyMapperSilicon.xcodeproj/
```

- [ ] **Step 2: Commit the removal**

```bash
git add -A
git commit -m "chore: remove CocoaPods and old Xcode project files"
```

### Task 6: Generate Xcode project with Tuist and verify build

**Files:**
- Generated: `JoyMapperSilicon.xcodeproj/` (by Tuist, gitignored)
- Generated: `JoyMapperSilicon.xcworkspace/` (by Tuist, gitignored)

- [ ] **Step 1: Generate the project**

Run: `tuist generate --no-open`
Expected: Project generates successfully. Watch for warnings about missing files or incorrect paths.

If it fails, the most likely issues are:
- Source glob patterns not matching actual file locations
- Missing Info.plist paths
- Core Data model path issues

Fix any issues before proceeding.

- [ ] **Step 2: Build the main app target**

Run: `xcodebuild build -workspace JoyMapperSilicon.xcworkspace -scheme JoyMapperSilicon -destination 'platform=macOS' 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

Common issues to watch for:
- **`import JoyConSwift` failures**: The vendored framework target name must match exactly.
- **Missing Core Data generated classes**: Verify the xcdatamodeld is being compiled.
- **Storyboard/XIB linking errors**: Verify resource globs capture all localized variants.
- **Launcher embedding location**: The launcher should end up in `Contents/Library/LoginItems`. If it ends up in `Contents/Frameworks` instead, we need to add a custom copy files phase and remove the default embedding.

- [ ] **Step 3: Verify the launcher is in the right place**

Run: `find ~/Library/Developer/Xcode/DerivedData -path "*/JoyMapperSilicon.app/Contents/Library/LoginItems/JoyMapperSiliconLauncher.app" -maxdepth 8 2>/dev/null | head -1`

If the launcher isn't in `Contents/Library/LoginItems`, add a copy files phase to `Project.swift`:

In the main app target, add after `scripts`:
```swift
            copyFiles: [
                .copyFiles(
                    name: "Embed Login Items",
                    destination: .init(rawValue: "Contents/Library/LoginItems"),
                    subpath: nil,
                    files: [
                        .target(name: "JoyMapperSiliconLauncher"),
                    ]
                ),
            ],
```

And remove the launcher from `dependencies` if Tuist is auto-embedding it elsewhere.

- [ ] **Step 4: Build the launcher target independently**

Run: `xcodebuild build -workspace JoyMapperSilicon.xcworkspace -scheme JoyMapperSiliconLauncher -destination 'platform=macOS' 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit any fixes**

If any changes were needed to `Project.swift` during the build verification:

```bash
git add Project.swift
git commit -m "fix: adjust Tuist manifest for successful build"
```

### Task 7: Final verification

- [ ] **Step 1: Clean build from scratch**

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/JoyMapperSilicon-*
tuist generate --no-open
xcodebuild build -workspace JoyMapperSilicon.xcworkspace -scheme JoyMapperSilicon -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Verify all localized resources are present**

```bash
# Check the built app bundle has both en and ja localizations
find ~/Library/Developer/Xcode/DerivedData -path "*/JoyMapperSilicon.app/Contents/Resources/*.lproj" -maxdepth 8 -type d 2>/dev/null | head -4
```

Expected: Both `en.lproj` and `ja.lproj` directories present.

- [ ] **Step 3: Verify the set_build_number script ran**

Check the build output for the "Set build number" script phase running. If the script fails during build (e.g., because it uses git commands that depend on repo layout), fix the script or adjust the `Project.swift` script phase.

---

## Notes

- **Why framework (not static library) for JoyConSwift?**: Using `.framework` preserves the `import JoyConSwift` module name without any code changes. A static library would also work but may need `DEFINES_MODULE` set explicitly.
- **Launcher embedding**: The launcher app is used for "Launch on Login" via `SMLoginItemSetEnabled`. macOS requires it to be in `Contents/Library/LoginItems`. Tuist's default dependency embedding puts things in `Contents/Frameworks`, so we may need the custom copy files phase described in Task 6, Step 3.
- **Tuist generates schemes**: The old hand-crafted `.xcscheme` file is no longer needed. Tuist creates schemes for each target automatically.
- **No workspace needed in commands if only one project**: After migration, `xcodebuild -project` may work, but Tuist typically generates a workspace. Use `-workspace` to be safe.
- **The old xcodeproj had `MACOSX_DEPLOYMENT_TARGET = 10.14`** but the Podfile required macOS 11.0. We're using 11.0 consistently now.
