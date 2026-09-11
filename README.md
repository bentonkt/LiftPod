# LiftPod

LiftPod is a minimal native iPhone utility that displays raw motion samples from compatible AirPods and records those samples to CSV. It uses Apple's public `CMHeadphoneMotionManager` API and requires iOS 18.0 or later.

## Requirements and setup

- Xcode 16 or later and an iPhone running iOS 18.0 or later
- Compatible AirPods with headphone motion support
- A physical iPhone for real motion data; the simulator cannot provide AirPods motion samples

Open `LiftPod.xcodeproj` in Xcode. Select the LiftPod app target, open Signing & Capabilities, and choose your own development team. Build and run on the iPhone. The project can be regenerated after editing `project.yml` with:

```sh
xcodegen generate
```

Motion permission is required so the app can read, display, and save raw AirPods sensor readings. Press **Start Motion** and grant permission when prompted. The status area reports permission, availability, connection, and stream state. Press **Stop Motion** to end the stream.

While motion monitoring is active, press **Start Recording** to write every callback to a CSV. Press **Stop Recording** to flush and close the file, then use **Export Last Recording** to open the standard iOS share sheet.

## CSV columns

Each file contains one header followed by one row per recorded callback:

| Column | Definition and unit |
| --- | --- |
| `index` | Sequential callback number for the monitoring run |
| `source_timestamp` | Core Motion monotonic timestamp, seconds |
| `receipt_uptime` | Local monotonic system uptime at receipt, seconds |
| `sensor_location` | Reported left headphone, right headphone, default, or unknown raw value |
| `user_acceleration_x/y/z` | User acceleration, g |
| `gravity_x/y/z` | Gravity vector, g |
| `rotation_rate_x/y/z` | Rotation rate, radians per second |
| `quaternion_w/x/y/z` | Attitude quaternion components |
| `roll`, `pitch`, `yaw` | Attitude angles, radians |

## Physical-device smoke test

This procedure requires real hardware and is not performed by automated tests:

1. Install the application on a physical iPhone running iOS 18 or later.
2. Connect compatible AirPods.
3. Open the app and grant motion permission.
4. Press Start Motion.
5. Confirm that the connection or waiting state is visible.
6. Move one AirPod.
7. Confirm that raw values and callback count change.
8. Confirm that the reported sensor location is visible.
9. Press Start Recording.
10. Move the AirPod for several seconds.
11. Press Stop Recording.
12. Export the CSV.
13. Confirm that the CSV contains a header and multiple data rows.
14. Confirm that each row contains the reported sensor location and raw motion fields.
15. Disconnect the AirPods and confirm that the app reports the interruption without crashing.

For testing with an AirPod outside the ear, manually disable Automatic Ear Detection in iOS Settings.
