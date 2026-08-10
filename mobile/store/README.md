# App Store listing assets

Screenshots captured from simulators against a seeded local relay, at the exact
sizes App Store Connect accepts.

| Folder | Device | Size | ASC display type |
| --- | --- | --- | --- |
| `screenshots/iphone-6.9` | iPhone 17 Pro Max | 1320 × 2868 | `APP_IPHONE_69` |
| `screenshots/ipad-13` | iPad Pro 13-inch (M5) | 2064 × 2752 | `APP_IPAD_PRO_3GEN_129` |

Upload with:

```
asc screenshots upload --app 6799497310 --version 1.0 \
  --path ./mobile/store/screenshots/iphone-6.9 --device-type APP_IPHONE_69
asc screenshots upload --app 6799497310 --version 1.0 \
  --path ./mobile/store/screenshots/ipad-13 --device-type APP_IPAD_PRO_3GEN_129
```

Order is taken from the file name prefix.
