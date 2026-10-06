<p align="center">
  <img src="assets/x-touchdown-logo.png" alt="X-Touchdown — Camera Effect" width="240">
</p>

# X-Touchdown

A configurable touchdown camera effect for **X-Plane 12 and FlyWithLua**, with separate main-gear and nose-gear impulses, optional impact sounds, and X-Camera integration.

**Current version: 1.12**

## Features

- A short vertical camera impulse with gentle pitch movement and damped settling.
- Main-gear touchdown detection using the last airborne vertical speed.
- A separate, softer impulse when the nose gear touches down later.
- Adjustable intensity for each aircraft ICAO type.
- Per-aircraft settings for master strength, aircraft strength, vertical movement, pitch, duration, nose-gear strength and index, sensitivity, impulse normalization, sound, camera mode, and X-Camera Script ID.
- Three original synthetic impact sounds: **Light**, **Medium**, and **Heavy**, with volume and mute controls.
- Test buttons for **−100, −200, −300, −400, and −600 fpm**.
- **TEST NOSE GEAR** and **TEST MAIN + NOSE** previews.
- FlyWithLua menu entry and assignable keyboard/joystick commands.
- Normal X-Plane camera output or X-Camera's documented Lua effect offsets.

## Requirements

- X-Plane 12.
- FlyWithLua with ImGui floating-window support.
- Optional: X-Camera with its Lua Script effect interface.

## Installation

1. Download the repository using **Code → Download ZIP** and extract it.
2. Copy `Touchdown_Camera_Effect_XP12.lua` and the complete `Touchdown_Camera_Sounds` folder into:

   ```text
   X-Plane 12/Resources/plugins/FlyWithLua/Scripts/
   ```

3. Replace an older copy of the script. Keep your existing `Touchdown_Camera_Effect_XP12.cfg`.
4. Restart X-Plane or reload FlyWithLua scripts.

Keep only one copy of the Lua script in the active Scripts folder. The `assets` folder is for this README and does not need to be installed.

## Open the settings

Hover over a label or control for a short English explanation. The window starts closed. Open it through:

**Plugins → FlyWithLua → FlyWithLua Macros → Touchdown Camera Effect – Open settings**

You can also assign these commands in X-Plane's keyboard or joystick settings:

| Command | Action |
| --- | --- |
| `xbrief/touchdown_camera/open_settings` | Open the settings window |
| `xbrief/touchdown_camera/toggle_settings` | Open or close the settings window |

## Tune and save an aircraft

Use the normal 3D cockpit view and start with a **−200 fpm** test. Adjust **Master strength**, **Aircraft strength**, **Vertical movement**, **Pitch movement**, and **Duration** to taste. Pitch can be set from 0 to 5 degrees and duration from 0.15 to 2 seconds. The actual pitch impulse also scales with landing intensity and both strength multipliers.

Click **Save aircraft settings** to write `Touchdown_Camera_Effect_XP12.cfg` beside the script. The window confirms the saved aircraft or displays a write error. Settings restore when that aircraft type is loaded again. For example, B763 and B752 can have different durations and intensities.

Profiles are keyed by **ICAO aircraft type**, not by livery or aircraft folder. Changes are kept in memory while the script runs; saving is required to retain them after a reload or restart. **Reset current aircraft** resets the current profile; save afterwards to retain the reset.

Existing configs from earlier versions remain supported.

## Landing sensitivity (v1.12)

**Full effect at** sets the sink rate magnitude at which the camera reaches full landing intensity (100–1000 fpm). Lower values make normal landings more noticeable. Sink rates below 40 fpm still produce no effect; the response remains smooth and nonlinear.

**Normalize impulse peak** removes the waveform's initial peak attenuation. At full landing intensity and master/aircraft strengths of 1.0, the first peak reaches the configured vertical and pitch movement. Strength multipliers can increase it further. Duration changes settling time, not peak amplitude.

The **CL60** default is **300 fpm with normalization enabled**. At −200 fpm and strengths of 1.0, Pitch 5 degrees yields about **2.6 degrees** instead of the previous 0.43 degrees. These defaults are tuning suggestions, not a physical calibration of the Hot Start aircraft. Start with modest movement values and a −100/−200 fpm preview if your previous settings were very high.

Other aircraft retain **700 fpm with normalization disabled**, preserving their previous effect. Existing CL60 configs retain all earlier controls and adopt the new sensitivity defaults if those fields are absent. Both new controls save per ICAO; to recover the old CL60 response, select 700 fpm and disable normalization, then save.

## Nose gear

The nose-gear impulse defaults to **35%** of the main-touchdown reference intensity. The real event follows actual nose-wheel contact; it does not use a fixed delay.

The default nose-gear array index is **0**. Aircraft may use a different gear order. Check the **Nose contact: AIR/GROUND** indicator and adjust the index if necessary. Set nose-gear strength to **0** for aircraft without a nose wheel.

After main-gear touchdown the aircraft's vertical speed may already be near zero. The secondary impulse therefore uses the main-landing intensity as its reference, scaled by the nose-gear strength setting; it is not a separate measurement of nose-wheel impact speed.

**TEST MAIN + NOSE** previews a −200 fpm main touchdown followed by a nose impulse after **1.5 seconds**. This fixed delay applies only to the preview. Short airborne bounces do not rearm a new landing; two seconds of continuous airborne time does.

## X-Camera setup

1. Select your cockpit camera in X-Camera.
2. Under **Effect Plugins**, choose **Lua Script**.
3. Set the camera's **Script ID** to **767**, or another unique positive ID.
4. Enter the same ID in X-Touchdown's **X-Camera Script ID** field.
5. Choose **Auto** or **X-Camera** and check the camera status line.
6. Press a touchdown test, then **Save aircraft settings**.

Use an ID that is not already assigned to another Lua effect. X-Camera accepts one Effect Plugin source per camera.

| Mode | Behavior |
| --- | --- |
| Auto | Uses X-Camera when its status is nonzero and the selected Script ID matches. Uses the normal X-Plane route when X-Camera is absent or reports status 0. Waits if X-Camera reports a different active Script ID. |
| X-Plane | Uses pilot-head position and pitch datarefs. Use this mode with X-Camera disabled. |
| X-Camera | Uses X-Camera Y and pitch effect offsets when the selected Script ID matches; otherwise waits. |

Use **Refresh X-Camera** if the plugin was loaded after the script. Changing the camera route or Script ID stops the current impulse.

Reference: [X-Camera 2.4.4 User Guide](https://www.stickandrudderstudios.com/downloads/X-Camera_User_Guide_2.4.4.pdf), *Offset Method* and *Script ID Usage*.

## Sounds

Choose **Light**, **Medium**, or **Heavy** manually. The selected sound plays on real touchdowns and on test impulses; it is not selected automatically by sink rate. The nose sound is reduced by the nose-gear strength multiplier.

The WAV files have increased base volume, with peaks normalized to 95 percent to avoid clipping. All three included WAV files were synthesized for this project, without third-party recordings or samples. Missing sound files leave the camera effect available and show a status message.

## Compatibility and testing

Use the normal 3D cockpit view. Other camera effects or head-tracking plugins can compete with direct pilot-head writes. X-Camera mode uses its effect-offset interface instead.

The script does not automatically change X-Plane's **G-Loaded camera** setting. The feel and behavior of combined effects require simulator testing.

Lua logic checks cover separate main/nose events, short-bounce suppression, tests, camera offset cleanup, X-Camera routing and Script ID changes, and per-aircraft save/reload behavior. These checks use simulated host functions and do not replace testing in X-Plane. FlightFactor-specific gear order and runtime behavior still need verification.

## Troubleshooting

- **No X-Camera movement:** confirm Lua Script is enabled on the selected view, match the Script ID, and check the status line.
- **No nose effect:** check the nose-gear index and ensure nose strength is above zero.
- **No sound:** ensure the complete `Touchdown_Camera_Sounds` folder is beside the Lua file and sound/volume are enabled.
- **Settings error:** note the message in the window and provide X-Plane's `Log.txt`.
- **Crash:** report the script version, aircraft, camera mode, action that triggered it, and `Log.txt` from that run.

X-Touchdown is an independent project and is not affiliated with Laminar Research, FlightFactor, Stick and Rudder Studios, or the FlyWithLua project.
