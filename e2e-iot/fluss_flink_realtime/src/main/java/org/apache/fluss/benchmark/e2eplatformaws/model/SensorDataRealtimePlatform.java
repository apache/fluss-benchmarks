/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.apache.fluss.benchmark.e2eplatformaws.model;

import java.io.Serializable;
import java.time.Instant;

/**
 * Sensor Data Model matching RealtimeDataPlatform benchmark.sensors_local schema.
 * This model matches the realtime IoT platform producer schema used in the E2E benchmark.
 * 
 * Only essential fields are stored in Fluss table. Remaining fields are set to default values at the sink.
 */
public class SensorDataRealtimePlatform implements Serializable {
    // Device identifiers
    private String deviceId;
    private String deviceType;
    private String customerId;
    private String siteId;
    
    // Location data
    private double latitude;
    private double longitude;
    private float altitude;  // Default value at sink: 0.0
    
    // Timestamp
    private Instant time;
    
    // Sensor readings (stored in Fluss)
    private float temperature;
    private float humidity;
    private float pressure;
    
    // Additional sensor readings (default values at sink)
    private float co2Level;  // Default: 0.0
    private float noiseLevel;  // Default: 0.0
    private float lightLevel;  // Default: 0.0
    private int motionDetected;  // Default: 0
    
    // Device metrics (stored in Fluss: battery_level only)
    private float batteryLevel;
    private float signalStrength;  // Default: 0.0
    private float memoryUsage;  // Default: 0.0
    private float cpuUsage;  // Default: 0.0
    
    // Status (stored in Fluss as INT: 1=online, 2=offline, 3=maintenance, 4=error)
    private int status;
    private long errorCount;  // Default: 0L
    
    // Network metrics (default values at sink)
    private long packetsSent;  // Default: 0L
    private long packetsReceived;  // Default: 0L
    private long bytesSent;  // Default: 0L
    private long bytesReceived;  // Default: 0L

    public SensorDataRealtimePlatform() {}

    // Getters and Setters
    public String getDeviceId() { return deviceId; }
    public void setDeviceId(String deviceId) { this.deviceId = deviceId; }
    
    public String getDeviceType() { return deviceType; }
    public void setDeviceType(String deviceType) { this.deviceType = deviceType; }
    
    public String getCustomerId() { return customerId; }
    public void setCustomerId(String customerId) { this.customerId = customerId; }
    
    public String getSiteId() { return siteId; }
    public void setSiteId(String siteId) { this.siteId = siteId; }
    
    public double getLatitude() { return latitude; }
    public void setLatitude(double latitude) { this.latitude = latitude; }
    
    public double getLongitude() { return longitude; }
    public void setLongitude(double longitude) { this.longitude = longitude; }
    
    public float getAltitude() { return altitude; }
    public void setAltitude(float altitude) { this.altitude = altitude; }
    
    public Instant getTime() { return time; }
    public void setTime(Instant time) { this.time = time; }
    
    public float getTemperature() { return temperature; }
    public void setTemperature(float temperature) { this.temperature = temperature; }
    
    public float getHumidity() { return humidity; }
    public void setHumidity(float humidity) { this.humidity = humidity; }
    
    public float getPressure() { return pressure; }
    public void setPressure(float pressure) { this.pressure = pressure; }
    
    public float getCo2Level() { return co2Level; }
    public void setCo2Level(float co2Level) { this.co2Level = co2Level; }
    
    public float getNoiseLevel() { return noiseLevel; }
    public void setNoiseLevel(float noiseLevel) { this.noiseLevel = noiseLevel; }
    
    public float getLightLevel() { return lightLevel; }
    public void setLightLevel(float lightLevel) { this.lightLevel = lightLevel; }
    
    public int getMotionDetected() { return motionDetected; }
    public void setMotionDetected(int motionDetected) { this.motionDetected = motionDetected; }
    
    public float getBatteryLevel() { return batteryLevel; }
    public void setBatteryLevel(float batteryLevel) { this.batteryLevel = batteryLevel; }
    
    public float getSignalStrength() { return signalStrength; }
    public void setSignalStrength(float signalStrength) { this.signalStrength = signalStrength; }
    
    public float getMemoryUsage() { return memoryUsage; }
    public void setMemoryUsage(float memoryUsage) { this.memoryUsage = memoryUsage; }
    
    public float getCpuUsage() { return cpuUsage; }
    public void setCpuUsage(float cpuUsage) { this.cpuUsage = cpuUsage; }
    
    public int getStatus() { return status; }
    public void setStatus(int status) { this.status = status; }
    
    public long getErrorCount() { return errorCount; }
    public void setErrorCount(long errorCount) { this.errorCount = errorCount; }
    
    public long getPacketsSent() { return packetsSent; }
    public void setPacketsSent(long packetsSent) { this.packetsSent = packetsSent; }
    
    public long getPacketsReceived() { return packetsReceived; }
    public void setPacketsReceived(long packetsReceived) { this.packetsReceived = packetsReceived; }
    
    public long getBytesSent() { return bytesSent; }
    public void setBytesSent(long bytesSent) { this.bytesSent = bytesSent; }
    
    public long getBytesReceived() { return bytesReceived; }
    public void setBytesReceived(long bytesReceived) { this.bytesReceived = bytesReceived; }
}


