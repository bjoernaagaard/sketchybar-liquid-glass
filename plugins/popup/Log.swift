import os

let logger = Logger(subsystem: "com.bjoernaagaard.sketchybar", category: "popup")

let interactionLogger = Logger(subsystem: "com.bjoernaagaard.sketchybar", category: "popup.interaction")

let motionLogger = Logger(subsystem: "com.bjoernaagaard.sketchybar", category: "motion")
// Instruments and the recordings read these intervals: one "spring" per island, from the retarget that starts
// its motion to the frame where it settles.
let motionSignposter = OSSignposter(subsystem: "com.bjoernaagaard.sketchybar", category: "motion")
