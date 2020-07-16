# XvMuse

I've built a Muse framework in Swift using XCode 11.5, Mac OS Catalina.

### Testing Environment ###
• Tested on MacOS Catalina using XCode's MacCatalyst.<br>
• Tested using the Muse 2 (2016) headband 


All the Swift code and libraries are iOS, so it *should* work on iOS devices.

### Known issues: ###

The Muse 1 (2016) headband can initially connect to the Bluetooth central manager, but it does not register the available services (which are needed to get EEG, Accelometer, Battery, etc... data). The only service that is reported is the Command service, which is used to send requests to the device. Perhaps there is a command the Muse 1 needs to receive in order to activate its other services during a Bluetooth session.

### Install ###

Coming Soon

### Usage ###

Once the framework is installed in your project, you need to choose a class that receives the data from the Muse. Using the main ViewController is an easy option:

At the top of the class, add:
```
import XvMuse
```

Extend the class as an XvMuseObserver. For example if you are using the main ViewController, it would be:

```
class ViewController:UIViewController, XvMuseObserver {
```

Do a Build and it will warn you:

> Type 'ViewController' does not conform to protocol 'XvMuseObserver'

Click on the XCode warning and it will offer to add the protocol stubs. Or you can add them yourself:

```
func didReceiveUpdate(from battery: XvMuseBattery) {}
func didReceiveUpdate(from accelerometer: XvMuseAccelerometer) {}
func didReceiveUpdate(from eeg: XvMuseEEG) {}
func didReceiveUpdate(from eegPacket: XvMuseEEGPacket) {}
```

This is how your project will receive data from the Muse headband. 

<hr>

## EEG ##

### Summary ###

Inside the XvMuseEEG packet you can access each sensor and each brainwave through a variety of methods. You can also obtain averages for head regions or the entire headband. Readings can be the entire frequency spectrum or specific frequencies like delta, theta, alpha, beta, and gamma bands.


### Values: Magnitudes vs. Decibels ###

A value can be accessed as a magnitude or a decibel value.

Both values come from the Fast Fourier Transform process. Magnitude is the more raw value, calculating the amplitude of the FFT by running vDSP_zvabsD on a DSPDoubleSplitComplex. The output is always above zero and I've seen values as high as 250000, with averages around 300-400. These are large values, but could be scaled down to more usable ranges.

The decibel value is calculated by taking the magnitude, running vDSP_vsdivD (divide), vDSP_vdbconD (convert to decibels), and vDSP_vsaddD (a gain correction after using a hamming window earlier in the process). In my tests, I've seen values go from -50 up to 65, with the average floating around -1 to 1.

For EEG values, there is no universal scale or baseline. Each user has different values and ranges, based on their brain and the situation they're in. I've had sensors output 0-5 in my studio, and have those same values over 70 in a performance setting. Processing EEG data is relative: look for how the waves behave compared to each other. Each developer can use and scale these values in the way that works best for them and their application.



### Accessing Sensors ###

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

These gives you the full frequency spectrum (called a Power Spectral Density) of the sensor.

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

These give you the same value. The two routes to the same data are just a matter of preference and what works for your project.


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

Relative values of the brainwaves can be accessed by sensor, region, or from the whole headband. A relative value is a percentage (range: 0.0-1.0) strength of a brainwave compared to the other brainwaves of that reading.

Examples:
```
let relativeAlphaForRightForehead:Double = eeg.rightForehead.alpha
let relativeBetaForFrontOfHead:Double = eee.front.beta
let relativeDeltaForEntireHead:Double = eeg.delta.relative
```

### History ###

Besides accessing the current decibel or magnitude of a wave, you can also access the history of values, up to the historyLength amount. The most recent value is at the beginning of the array, the oldest value is at the end. Having these values can be useful for rendering a wave's recent values on a graphic display.

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
This returns the average value divided by the highest value. "Percent" isn't the perfect word for this value, but it can be a useful for calculating how the wave is performing overall compared to it's most recent peak. This is not in decibels or magnitudes, but a 0.0-1.0 percentage range.
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

## EEG Packet ##

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

## PPG ##

In development.

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
