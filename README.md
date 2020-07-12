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

### Battery ###
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

### Accelerometer ###
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


### EEG ###

Coming soon.

### EEG Packet ###

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


### PPG ###

In development.
