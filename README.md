# XvMuse

I've built a Muse framework in Swift using XCode 11.1, Mac OS Catalina.

### Testing Environment ###
• Tested on MacOS Catalina using XCode's MacCatalyst.<br>
• Tested using the Muse 2 (2016) headband<br>
• Tested using the Muse 1 (2014). No PPG data is available on the Muse 1.<br>
• Data results appear similar to other frameworks<br>

All the Swift code and libraries are iOS, so it *should* work on iOS devices.


### Acknowledgements ###
I learned a ton from these frameworks and research sources:

Muse Python framework:<br>
https://github.com/alexandrebarachant/muse-lsl

Muse JS framework:<br>
https://github.com/urish/muse-js

Muse Bluetooth packets:<br>
https://articles.jaredcamins.com/figuring-out-bluetooth-low-energy-8c2a2716e376

Muse Serial Commands:<br>
https://sites.google.com/a/interaxon.ca/muse-developer-site/muse-communication-protocol/serial-commands

### Known issues: ###

<ul>
<li>There may be errors in the retrival or processing of the data, so I'm open to improvements. This is still a work in progress but I wanted to share it so others could utilize it.</li>
<li>The PPG heartbeat detection sensitiy may not be perfect. Still tweaking it to get an accurate tempo.</li>
<li>Breath detection is not created yet.</li>
<li>Device often disconnects. I'm studying the Muse Communication Protocol to address this (https://sites.google.com/a/interaxon.ca/muse-developer-site/muse-communication-protocol)</li>
</ul>

### Install ###

The installation method I use is to import the XvMuse Xcode Project to my main Xcode Project

1. File > Add Files > Select XvMuse Xcode project
1. Check the Add to targets checkbox
1. In the Xcode Navigator, navigate to XvMuse.xcodeproj > Private > Products > XvMuse.framework
1. Drag this framework to the main Xcode project > Targets > Frameworks, Libraries, and Embedded Content
1. I select "macOS and iOS" and "Embed & Sign" (I haven't tested other set ups)

### Usage ###

Once the framework is installed in your project, you need to choose a class that receives the data from the Muse. Using the main ViewController is an easy option:

At the top of the class, add:
```
import XvMuse
```

Extend the class as an XvMuseObserver. For example if you are using the main ViewController, it would be:

```
class ViewController:UIViewController, XvMuseDelegate {
```

Do a Build and it will warn you:

> Type 'ViewController' does not conform to protocol 'XvMuseDelegate'

Click on the XCode warning and it will offer to add the protocol stubs. Or you can add them yourself:

```
func didReceiveUpdate(from battery: XvMuseBattery) {}
func didReceiveUpdate(from accelerometer: XvMuseAccelerometer) {}
func didReceiveUpdate(from eeg: XvMuseEEG) {}
func didReceiveUpdate(from eegPacket: XvMuseEEGPacket) {}
func didReceiveUpdate(from ppg:XvMusePPG)
func didReceive(ppgHeartEvent:XvMusePPGHeartEvent)
func didReceive(ppgPacket:XvMusePPGPacket)
func didReceive(commandResponse:[String:Any])
func museIsConnecting()
func museDidConnect()
func museDidDisconnect()
func museLostConnection()
```

This is how your project will receive data from the Muse headband. 

<hr>

To create the XvMuse object, initialize it.

```
let muse:XvMuse = XvMuse()
```

I also set up some keyboard listeners in my main Xcode project to send commands into XvMuse. These could be button taps, key commands, etc... whatever works for you. The basic start / stop commands are:

```
func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    
    for press in presses {
        
        guard let key = press.key else { continue }
        
        switch key.characters {
        
        case "c":
            muse.bluetooth.connect()
        case "d":
            muse.bluetooth.disconnect()
        case "s":
            muse.bluetooth.startStreaming()
        case "p":
            muse.bluetooth.pauseStreaming()
            
        default:
            break
        }
    }
}

```

Run your app, let it launch, then execute:

```
muse.bluetooth.connect() 
```
If using the keyboard commands above, it's executed by pressing the letter "c".

When the app attempts to connect with only `let muse:XvMuse = XvMuse()`, it does a search for all the nearby Bluetooth devices. Make sure your Muse headband is turned on, and when XvMuse finds it, it will print to the output window:


> Discovered (Your Muse's Headband Name) headband with ID: (Your Muse's Bluetooth ID)

> Use the line below to intialize the XvMuse framework with this Muse device.

> let muse:XvMuse = XvMuse(deviceID: "(Your Muse's Bluetooth ID)")

Replace `let muse:XvMuse = XvMuse()` with `let muse:XvMuse = XvMuse(deviceID: "(Your Muse's Bluetooth ID)")`

This is the way to have the XvMuse framework know which Muse headband to connect with.

Relaunch the app. Now when you execute `muse.bluetooth.connect()`, it will look for your headband. The output window will display information about attempting the connection, then discovering the target device, and finally discovering the device's Bluetooth characterisitcs ("char"). Once the characteristics are discovered, you can safely execute:

```
muse.bluetooth.startStreaming() 
```

Live data from the headband will start streaming in. The Muse 1 will fire off these functions in your XvMuseDelegate class:

```
func didReceiveUpdate(from eeg:XvMuseEEG)
func didReceive(eegPacket:XvMuseEEGPacket)
func didReceiveUpdate(from accelerometer:XvMuseAccelerometer)
func didReceiveUpdate(from battery:XvMuseBattery)
```

The Muse 2 will fire off these and PPG data:

```
func didReceiveUpdate(from ppg:XvMusePPG)
func didReceive(ppgHeartEvent:XvMusePPGHeartEvent)
func didReceive(ppgPacket:XvMusePPGPacket)
```

Through these functions, you can access the Muse's data and use it for your main Xcode project.


## XvMuseEEG Object ##

### Summary ###

Inside the XvMuseEEG packet you can access each sensor and each brainwave through a variety of methods. You can also obtain averages for head regions or the entire headband. Readings can be the entire frequency spectrum or specific frequencies like delta, theta, alpha, beta, and gamma bands.


### Values: Magnitudes vs. Decibels ###

A value can be accessed as a magnitude or a decibel value.

Both values come from the Fast Fourier Transform process. Magnitude is the more raw value, calculating the amplitude of the FFT by running vDSP_zvabsD on a DSPDoubleSplitComplex. The output is always above zero and I've seen values as high as 250000, with averages around 300-400. These are large values, but could be scaled down to more usable ranges.

The decibel value is calculated by taking the magnitude, running vDSP_vsdivD (divide), vDSP_vdbconD (convert to decibels), and vDSP_vsaddD (a gain correction after using a hamming window earlier in the process). In my tests, I've seen values go from -50 up to 65, with the average floating around -1 to 1.

For EEG values, there is no universal scale or baseline. Each user has different values and ranges, based on their brain and the situation they're in. I've had sensors output 0-5 in my studio, and have those same values over 70 in a performance setting. Processing EEG data is relative: I look for how the waves behave compared to each other. Each developer can use and scale these values in the way that works best for them and their application.



### Accessing EEG Sensors ###

You can access the 4 sensors on the Muse through their electrode number, array position, or a user-friendly location name.


#### Left Ear ####
```
eeg.TP9
eeg.sensors[0]
eeg.leftEar
```

#### Left Forehead ####
```
eeg.FP1
eeg.sensors[1]
eeg.leftForehead
```

#### Right Forehead ####
```
eeg.FP2
eeg.sensors[2]
eeg.rightForehead
```

#### Right Ear ####
```
eeg.TP10
eeg.sensors[3]
eeg.rightEar
```

For each sensor, you can access either the decibels or magnitudes.

Examples:
```
let TP9Decibles:[Double] = eeg.TP9.decibel
let rightForeheadMagnitudes:[Double] = eeg.rightForehead.magnitude
```

These gives you the full frequency spectrum (called a Power Spectral Density) of the sensor. This value updates on every data refresh coming off the headband.

Besides accessing individual sensors, you can access an averaged readout for a region.

#### Left Side of the Head ####
```
eeg.left
```

#### Right Side of the Head ####
```
eeg.right
```

#### Front of the Head (Forehead) ####
```
eeg.front
```

#### Sides of the Head (Ears) ####
```
eeg.sides
```

Examples:
```
let leftSideOfHeadDecibels:[Double] = eeg.left.decibels
let frontOfHeadMagnitudes:[Double] = eeg.front.magnitudes
```

Finally, you can access all the sensors averaged together.

#### Entire Head ####
```
eeg
```

Examples:
```
let allSensorsAveragedInDecibels:[Double] = eeg.decibels
let allSensorsAveragedInMagnitudes:[Double] = eeg.magnitudes
```

Again, all the examples above give you access to the full frequency spectrum of the sensor data. Next is how to access commonly-used frequency bands such as delta, alpha, etc...


### Brainwaves ###

The full frequency spectrum's output is 0-110Hz. The commonly-used bands are at these frequencies:

> Delta:    1-4Hz<br>
> Theta:    4-8Hz<br>
> Alpha:    7.5-13Hz<br>
> Beta:     13-30Hz<br>
> Gamma:    30-44Hz

You can access these values for each sensor, region, or for the entire headband. The accessors are
```
.delta
.theta
.alpha
.beta
.gamma

.waves[0] // delta
.waves[1] // theta
.waves[2] // alpha
.waves[3] // beta
.waves[4] // gamma
```

#### By Sensor ####

To access the brainwave from a specific sensor, you have two options. You can start with the sensor or the brainwave.

Examples:
```
let leftForeheadDelta:Double = eeg.leftForehead.delta.decibel
let deltaOfLeftForehead:Double = eeg.delta.leftForehead.decibel //same value as above
let leftForeheadDeltafromWavesArray:Double = eeg.leftForehead.waves[0].decibel //same value
let deltaOfLeftForeheadFromWavesArray:Double = eeg.waves[0].leftForehead.decibel //same value
```

These methods give you the same value. Which route to use is just a matter of preference and what works for your project.


#### By Region ####

To access the averaged brainwave level from a region of sensors, you have two options. You can start with the region or the brainwave. The two examples below output the same value.

Examples:
```
let frontOfHeadDelta:Double = eeg.front.delta.decibel
let deltaOfFrontOfHead:Double = eeg.delta.front.decibel
```

#### By Entire Headband ####

To access the averaged brainwave level of the entire headband, just target the wave directly.

Examples:
```
let deltaAverageDecibelValueForEntireHead:Double = eeg.delta.decibel
let deltaAverageMagnitudeValueForEntireHead:Double = eeg.delta.magnitude
```

### Relative Values ###
Relative values of the brainwaves can be accessed by sensor, region, or from the whole headband. A relative value is a percentage (range: 0.0-1.0) strength of a brainwave when compared to other brainwaves or to its own recent values.

#### Relative to other brainwaves ####

This returns the strength of a brainwave compared to the other brainwaves.

Examples:
```
let relativeAlphaForRightForehead:Double = eeg.rightForehead.alpha.relative
let relativeBetaForFrontOfHead:Double = eee.front.beta.relative
let relativeDeltaForEntireHead:Double = eeg.delta.relative
```

#### Relative to its own recent values ####

This returns the strength of a brainwave compared to its own recent values (more details in History section below).

Examples:
```
let deltaPercentageForLeftEar:Double = eeg.leftEar.delta.percent
let gammaPercentageForSideSensors:Double = eee.sides.gamma.percent
let thetaPercentageForEntireHead:Double = eeg.theta.percent
```

### History ###

Besides accessing the current decibel or magnitude of a wave, you can also access the history of values, up to the historyLength amount. The most recent value is at the end of the array. Having these values can be useful for rendering a wave's recent values on a graphic display.

Examples:
```
let historyOfDeltaDecibelValuesForEntireHead:[Double] = eeg.delta.history.decibels
let historyOfDeltaMagnitudeValuesForLeftForehead:[Double] = eeg.leftForehead.delta.history.magnitudes
```

To change the length of the wave's history, call
```
eeg.set(historyLength: 150) // default is 75.
```

In the history object, you can access a few properties about it.

#### Highest ####
This returns the highest decibel or magnitude from the history array.
```
let highestRecentDeltaDecibelForEntireHead:Double = eeg.delta.history.highest.decibel
```
#### Lowest ####
This returns the lowest decibel or magnitude from the history array.
```
let lowestRecentAlphaMagnitudeForEntireHead:Double = eeg.alpha.history.lowest.magnitude
```
#### Range ####
This returns the range of decibels or magnitudes in the history array (i.e. highest-lowest values)
```
let rangeOfRecentBetaDecibelsForLeftEarSensor:Double = eeg.leftEar.beta.history.range.decibel
```
#### Sum ####
This returns the sum of the history array, in decibels or magnitudes.
```
let sumOfRecentGammaMagnitudesForForeheadSensors:Double = eeg.front.gamma.history.sum.magnitude
```
#### Average ####
This returns the average value of the history array, in decibels or magnitudes.
```
let averageOfRecentThetaDecibelsForTP10Sensor:Double = eeg.TP10.theta.average.decibel
```
#### Percent ####
This returns the most recent value divided by the highest value in its history. 
```
let deltaHistoryPercent:Double = eeg.sides.delta.history.percent
```

### Custom Frequency Bands ###

If you want to get data from from the frequency spectrum besides the presets (delta, theta, alpha, beta, and gamma), you can pass in your own range and retrive decibel and magnitude data from any sensor, region, or the entire headband. There are several methods available to get custom spectrum data.


#### By Frequency Range ####
```
getDecibel(fromFrequencyRange:[Double]) -> Double
getMagnitude(fromFrequencyRange:[Double]) -> Double
```

You can pass in an array of two frequencies and get back the averaged decibel or magnitude for that range. All values must be below 110Hz, since that is the range of the Muse headband's output.

Examples:
```
let customBandDecibelAverageForLeftEarSensor:Double = eeg.leftEar.getDecibel(fromFrequencyRange[4.5, 8.0])
let customBandDecibelAverageForFrontOfHead:Double = eeg.front.getDecibel(fromFrequencyRange[85.0, 60.0])
let custonBandMagnitudeAverageForEntireHead:[Double] = eeg.getMagnitude(fromFrequencyRange[33.0, 37.0])
```

#### By Bin Range ####

Calculating the frequency range repeatedly can slow things down, so you can calculate the frequencis into it "bin" numbers. This finds the bin location of your frequency in the spectrum and returns results faster.

To get your custom bin range:
```
let myCustomBins:[Int] = eeg.getBins(fromFrequencyRange: [4.5, 8.0])
```

Then you can get the averaged decibel or magnitude for that bin range.

```
let customBandDecibelAverageForLeftEarSensor:Double = eeg.getDecibel(fromBinRange: myCustomBins)
let customBandDecibelAverageForFrontOfHead:Double = eeg.front.getDecibel(fromBinRange: myCustomBins)
let custonBandMagnitudeAverageForEntireHead:Double = eeg.getMagnitude(fromBinRange: myCustomBins)
```

Again, this is computationally faster, so it can be worth calculating your bins once, and using those to get the decibel and magnitude values each time the headband refreshes.

### Spectrum Slices ###
Instead of getting an averaged value from a custom frequency slice, you can access the slice yourself for data processing or graphic display.


#### By Frequency Range ####
You can get a slice of the frequency spectrum in decibels or magnitudes by passing in a frequency range.

Examples:
```
let customDecibelSliceOfSpectrum:[Double] = eeg.getDecibelSlice(fromFrequencyRange: [18.0, 23.0])
let customMagnitudeSliceOfSpectrum:[Double] = eeg.getMagnitudeSlice(fromFrequencyRange: [8.5, 10.3])
```

#### By Bin Range ####

And similar to above, you can calcuate the bins of your frequency range, and use the bin range get a spectrum slice

```
let myCustomBins:[Int] = eeg.getBins(fromFrequencyRange: [4.5, 8.0])
let customDecibelSliceOfSpectrum:[Double] = eeg.getDecibelSlice(fromBinRange: myCustomBins)
let customMagnitudeSliceOfSpectrum:[Double] = eeg.getMagnitudeSlice(fromBinRange: myCustomBins)
```
<hr>

## XvMuseEEGPacket Object ##

The majority of users won't need this update since you can get the processed EEG data from the XvMuseEEG update above. However, if someone wants to process their own Fast Fourier Transform from the Muse's raw EEG data, it can be done with these packets.

This is the most frequent update, firing each time one of the four sensors makes a reading. When the XvMuseEEGPacket comes in, it has the follow attributes:

```
eegPacket.packetIndex
eegPacket.timestamp
eegPacket.sensor
eegPacket.samples

```

.packetIndex is the sequential id of the packet.<br>
.timestamp is the milliseconds since the app launched.<br>
.samples is an array of 12 time-based readings from the sensor that sent this packet.<br>
.sensor is the ID of the sensor that sent this packet.<br>

Sensor 0 is TP10, behind the right ear<br>
Sensor 1 is AF8, the right forehead<br>
Sensor 2 is TP9, behind the left ear<br>
Sensor 3 is AF7, the left forehead<br>

(Note: This is not the same order of sensors in the XvMuseEEG object above. That was goes left-to-right across the head which is easier to remember. This order is the order in which the device sensors fire off updates.)

These time-based packets that can be loaded into a buffer, sliced into epochs, processed through a Fast Fourier Transform, and output as frequency-based spectrum data. This is all being done in the framework and output as the XvMuseEEG updates above. So, again, most users won't need to use this XvMuseEEGPacket update.

<hr>

## XvMusePPGHeartEvent Object ##

The Muse 2 introduced a PPG sensor which can be use to detect heart and breath data. This framework only accesses heart data so far. 

The most usable PPG object in XvMuse is XvMusePPGHeartEvent. It fires when the heart data goes above a peak threshold, signifying a heart beat. The object provides data about the heartbeat's amplitude and beats per minute.

### Heartbeat Amplitude ###

Any incoming XvMusePPGHeartEvent signifies a new heartbeat, but if you also want the amplitude of that heartbeat, you can access it this way:

```
ppgHeartEvent.amplitude
```

The heartbeat detection is still being worked on, so you can manually adust the peak threshold. The highest the threshold, the stronger the heart data needs to be to register a XvMusePPGHeartEvent. You can increase or decrease the PPG heartbeat peak threshold with the following commands in your main Xcode project:

```
muse.ppg.increaseHeartbeatPeakDetectionThreshold()
muse.ppg.decreaseHeartbeatPeakDetectionThreshold()
```


### Heartbeat Beats Per Minute ###

The XvMusePPGHeartEvent object also contains BPM data, including the most recent calculation and a smoothed out average.

```
ppgHeartEvent.currentBpm
ppgHeartEvent.averageBpm
```


## XvMusePPG Object ##

### Accessing PPG Sensors ###

You can access the 3 PPG sensors through the `sensors` array. 

```
ppg.sensors //sensors array
ppg.sensors[0] //sensor 1
ppg.sensors[1] //sensor 2
ppg.sensors[2] //sensor 3
```

They seem to have varying levels of sensitivity.

### Accessing Sensors Samples ###

The samples array is an Optional, which is nil when the sensor's are inactive. So it needs to be safely unpacked. For example:

```
if let samples:[Double] = ppg.sensors[1].samples {
    print("PPG samples:", samples)
}
```

These are the raw, time-based PPG samples. Use these samples if you are displaying an EKG readout or doing your own heartbeat detection algorithms.


### Accessing Sensors Frequency Spectrums ###

Still in development, but you can access a DCT (Discrete Fourier Transform) frequency spectrum of the PPG sensors, similar to the sample access above:

```
if let frequencySpectrum:[Double] = ppg.sensors[1].frequencySpectrum {
    print("PPG frequencySpectrum:", frequencySpectrum)
}
```

## XvMusePPGPacket Object ##

Similar to the XvMuseEEGPacket, this is the raw PPG packet stream. Again, the majority of users won't need this update but if you want to do your own sensor and sensor sample processing, this is the raw data. It has the follow attributes:

```
ppgPacket.packetIndex
ppgPacket.timestamp
ppgPacket.sensor
ppgPacket.samples

```




<hr>

## Accelerometer ##

The accelerometer updates frequently and registers headband movement. Each update contains 3 x, y, z readings. When the XvMuseAccelerometer object comes in, it has the following attributes:

```
accelerometer.packetIndex
accelerometer.raw
accelerometer.x
accelerometer.y
accelerometer.z

```

.packetIndex is the sequential id of the packet.<br>
.raw is a UInt16 array with 9 values. The headband takes 3 samplings of x, y, z for each update.<br>
The format of the raw array is: [x1, y1, z1, x2, y2, z2, x3, y3, z3]<br>
.x .y and .z are the averaged values of the raw array.

<hr>

## Battery ##

The updates from the battery are the least frequent, about every 30 seconds or so. When the XvMuseBattery object comes in, it has the following attributes:

```
battery.percentage
battery.packetIndex
battery.raw
```
.percentage is the most useful, telling you how charged the battery is (0-100).<br>
.packetIndex is the sequential order of this particular battery packet. Not that useful.<br>
.raw is a [UInt16] array containing the 4 battery traits, including the battery.<br>

UInt16 battery (divide by 512 to get the percentage)<br>
UInt16 fuel gauge (multiply by 2.2)<br>
UInt16 adc volt<br>
UInt16 temperature (I believe this is the temp of the battery, not the overall Muse headband)<br>


## Headband Commands ##

You can send commands and get device data from the Muse device by using the following commands:

#### Connect ####
```
muse.bluetooth.connect()
```
This attempts to connect with the device specified in the `XvMuse(deviceID:String)` init command.


#### Disconnect ####
```
muse.bluetooth.disconnect()
```

This disconnects the headband and interrupts streaming if active.


#### Start Streaming ####
```
muse.bluetooth.startStreaming()
```

Once the XvMuseDelegate receives the `museDidConnect()` event, it is safe to start streaming the data.

#### Pause Streaming ####
```
muse.bluetooth.pauseStreaming()
```

Pauses the data streaming. Resume it by calling `startStreaming()`

#### Control Status Data ####
```
muse.bluetooth.controlStatus()
```

Returns the following data:

* bp: Battery Percentage
* hn: device name
* id: unknown
* ma: Mac Address
* ps: PreSet
* rc: Response Code
* sn: Serial Number
* tc: unknown


#### Version Handshake Data ####
```
muse.bluetooth.versionHandshake()
```

This sets the protocol version to the more usable version (1, instead of 0) and returns the following data:


* ap: unknown
* bl: Boot Loader
* bn: firmware Build Number
* fw: FirmWare version
* hw: HardWare version
* pv: Protocol Version
* rc: Response Code
* sp: unknown
* tp: firmware TyPe (


#### Reset Muse ####
```
muse.bluetooth.resetMuse()
```

Resets the Muse.

#### Set Preset ####
```
muse.bluetooth.set(preset: XvMuseConstants.PRESET_21)
```

Activates a preset for the device. Default is 21. 4 options:

* PRESET_20: Using auxillary sensor
* PRESET_21: No auxillary sensor
* PRESET_22: Unknown
* PRESET_23: Unknown

#### Set Host Platform ####
```
muse.bluetooth.set(hostPlatform: XvMuseConstants.HOST_PLATFORM_MAC)
```

Selects a host platform, which can be useful for some Bluetooth connection issues. 5 options:

* HOST_PLATFORM_IOS
* HOST_PLATFORM_ANDROID
* HOST_PLATFORM_WINDOWS
* HOST_PLATFORM_MAC
* HOST_PLATFORM_LINUX






