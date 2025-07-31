#!/usr/bin/env python3
"""
LowState IMU Data Subscriber for Go2 Robot

This script subscribes to the rt/lowstate topic to read IMU data
from the Go2 robot's low-level state, which includes IMU data as part
of the robot state. This might have better data parsing than the direct
rt/utlidar/imu topic.

Usage:
    cd demo && uv run test_lowstate_imu.py
"""

import sys
import time
import signal
import math
from typing import Optional
from collections import deque

# Add the unitree SDK to the path
sys.path.append('./unitree_sdk2_python')

try:
    from unitree_sdk2py.core.channel import ChannelSubscriber, ChannelFactoryInitialize
    from unitree_sdk2py.idl.unitree_go.msg.dds_ import LowState_
except ImportError as e:
    print(f"Error importing unitree SDK: {e}")
    print("Make sure you've run: cd demo && ./setup.sh")
    sys.exit(1)


class LowStateIMUSubscriber:
    """LowState IMU data subscriber with IMU extraction"""
    
    def __init__(self, topic_name: str = "rt/lowstate"):
        self.topic_name = topic_name
        self.subscriber = None
        self.running = False
        self.message_count = 0
        self.start_time = None
        
        # Data buffers for averaging
        self.accel_buffer = deque(maxlen=10)
        self.gyro_buffer = deque(maxlen=10)
        self.temp_buffer = deque(maxlen=10)
        
        # Signal handling
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)
    
    def _signal_handler(self, signum, frame):
        """Handle shutdown signals"""
        print(f"\nReceived signal {signum}, shutting down...")
        self.stop()
    
    def start(self):
        """Start the LowState subscriber"""
        try:
            print(f"🔍 Starting LowState subscriber for topic: {self.topic_name}")
            print("📡 Connecting to Go2 robot via Zenoh bridge...")
            
            # Initialize the channel factory
            ChannelFactoryInitialize()
            
            # Create subscriber
            self.subscriber = ChannelSubscriber(self.topic_name, LowState_)
            self.subscriber.Init()
            
            print("✅ LowState subscriber started successfully!")
            print("📊 Press Ctrl+C to stop\n")
            
            self.running = True
            self.start_time = time.time()
            self._run()
            
        except Exception as e:
            print(f"❌ Error starting LowState subscriber: {e}")
            sys.exit(1)
    
    def _run(self):
        """Main subscription loop"""
        while self.running:
            try:
                # Read LowState data
                lowstate_data = self.subscriber.Read()
                if lowstate_data is not None:
                    self._process_lowstate_data(lowstate_data)
                    self.message_count += 1
                else:
                    time.sleep(0.001)  # Small delay if no data
                    
            except KeyboardInterrupt:
                break
            except Exception as e:
                print(f"⚠️  Error reading LowState data: {e}")
                time.sleep(0.1)
    
    def _process_lowstate_data(self, lowstate_data: LowState_):
        """Process and display IMU data from LowState"""
        try:
            # Extract IMU data from LowState
            imu_data = lowstate_data.imu_state
            
            # Extract raw data with proper type handling
            quaternion = list(imu_data.quaternion)
            gyroscope = list(imu_data.gyroscope)
            accelerometer = list(imu_data.accelerometer)
            rpy = list(imu_data.rpy)
            temperature = imu_data.temperature
            
            # Add to buffers for averaging
            self.accel_buffer.append(accelerometer)
            self.gyro_buffer.append(gyroscope)
            self.temp_buffer.append(temperature)
            
            # Calculate metrics
            accel_magnitude = math.sqrt(sum(x*x for x in accelerometer))
            gyro_magnitude = math.sqrt(sum(x*x for x in gyroscope))
            
            # Average values
            avg_accel = [sum(x[i] for x in self.accel_buffer) / len(self.accel_buffer) 
                        for i in range(3)] if self.accel_buffer else accelerometer
            avg_gyro = [sum(x[i] for x in self.gyro_buffer) / len(self.gyro_buffer) 
                       for i in range(3)] if self.gyro_buffer else gyroscope
            avg_temp = sum(self.temp_buffer) / len(self.temp_buffer) if self.temp_buffer else temperature
            
            # Calculate sample rate
            elapsed = time.time() - self.start_time
            sample_rate = self.message_count / elapsed if elapsed > 0 else 0
            
            # Display data
            print(f"[{self.message_count:04d}] LOWSTATE IMU DATA")
            print("=" * 50)
            print(f"RAW SENSOR DATA:")
            print(f"  Temperature:   {temperature:6.1f}°C (avg: {avg_temp:6.1f}°C)")
            print(f"  Quaternion:    [{quaternion[0]:8.4f}, {quaternion[1]:8.4f}, {quaternion[2]:8.4f}, {quaternion[3]:8.4f}]")
            print(f"  Gyroscope:     [{gyroscope[0]:8.4f}, {gyroscope[1]:8.4f}, {gyroscope[2]:8.4f}] rad/s")
            print(f"  Accelerometer: [{accelerometer[0]:8.4f}, {accelerometer[1]:8.4f}, {accelerometer[2]:8.4f}] m/s²")
            print(f"  RPY:           [{rpy[0]:8.4f}, {rpy[1]:8.4f}, {rpy[2]:8.4f}] rad")
            print(f"COMPUTED METRICS:")
            print(f"  Accel Magnitude: {accel_magnitude:8.4f} m/s²")
            print(f"  Gyro Magnitude:  {gyro_magnitude:8.4f} rad/s")
            print(f"  Movement:        {'YES' if accel_magnitude > 1.1 or gyro_magnitude > 0.1 else 'NO'}")
            print(f"DATA QUALITY:")
            print(f"  Buffer Size:     {len(self.accel_buffer)}/10")
            print(f"  Sample Rate:    ~{sample_rate:.1f} Hz")
            print()
            
        except Exception as e:
            print(f"⚠️  Error processing LowState IMU data: {e}")
    
    def stop(self):
        """Stop the LowState subscriber"""
        self.running = False
        if self.subscriber:
            try:
                self.subscriber.Close()
                print("✅ LowState subscriber stopped.")
            except Exception as e:
                print(f"⚠️  Error stopping subscriber: {e}")
        
        # Print summary
        if self.start_time:
            elapsed = time.time() - self.start_time
            rate = self.message_count / elapsed if elapsed > 0 else 0
            print(f"📊 Summary:")
            print(f"   Messages received: {self.message_count}")
            print(f"   Runtime: {elapsed:.1f} seconds")
            print(f"   Average rate: {rate:.1f} Hz")


def main():
    """Main function"""
    print("🤖 Go2 Robot LowState IMU Data Subscriber")
    print("=" * 50)
    
    subscriber = LowStateIMUSubscriber()
    subscriber.start()


if __name__ == "__main__":
    main() 