# Generating the StarryPreview.icns (Screen Saver List Icon)

This project now expects a custom icon named `StarryPreview.icns` (declared via CFBundleIconFile in Info.plist) so macOS shows a representative thumbnail of the actual starry sky.

Follow these steps to create / update the icon:

## 1. Produce a Clean Screenshot

1. Build & run the screen saver in a test harness (or install it temporarily).
2. Let it render for a moment until a pleasing distribution of stars, buildings, and the moon is visible.
3. Capture a screenshot:
   - Press `Cmd+Shift+4`, drag over the saver window, OR
   - Use command line for a specific window ID:
     ```
     screencapture -i starry_raw.png
     ```
4. Open the screenshot in Preview (or your editor) and crop to a perfect square focusing on an interesting portion (moon + skyline + stars). Recommended final working size: 1024×1024.

## 2. Prepare the Icon Set Directory

Create a temporary iconset folder:
