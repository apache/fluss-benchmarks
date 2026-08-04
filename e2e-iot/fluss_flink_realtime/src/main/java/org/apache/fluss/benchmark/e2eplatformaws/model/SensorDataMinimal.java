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

/**
 * Minimal sensor fields written by the Fluss producer (8 columns).
 * This matches the minimal schema used in RealtimeDataPlatform:
 * - sensorId (int)
 * - sensorType (int) - 1=temperature, 2=humidity, 3=pressure, 4=motion, 5=light, 6=co2, 7=noise, 8=multisensor
 * - temperature (double)
 * - humidity (double)
 * - pressure (double)
 * - batteryLevel (double)
 * - status (int) - 1=online, 2=offline, 3=maintenance, 4=error
 * - timestamp (long) - milliseconds since epoch
 */
public class SensorDataMinimal implements Serializable {
    private int sensorId;
    private int sensorType;
    private double temperature;
    private double humidity;
    private double pressure;
    private double batteryLevel;
    private int status;
    private long timestamp;

    public SensorDataMinimal() {}

    public SensorDataMinimal(int sensorId, int sensorType, double temperature, double humidity,
                         double pressure, double batteryLevel, int status, long timestamp) {
        this.sensorId = sensorId;
        this.sensorType = sensorType;
        this.temperature = temperature;
        this.humidity = humidity;
        this.pressure = pressure;
        this.batteryLevel = batteryLevel;
        this.status = status;
        this.timestamp = timestamp;
    }

    // Getters and Setters
    public int getSensorId() { return sensorId; }
    public void setSensorId(int sensorId) { this.sensorId = sensorId; }
    
    public int getSensorType() { return sensorType; }
    public void setSensorType(int sensorType) { this.sensorType = sensorType; }
    
    public double getTemperature() { return temperature; }
    public void setTemperature(double temperature) { this.temperature = temperature; }
    
    public double getHumidity() { return humidity; }
    public void setHumidity(double humidity) { this.humidity = humidity; }
    
    public double getPressure() { return pressure; }
    public void setPressure(double pressure) { this.pressure = pressure; }
    
    public double getBatteryLevel() { return batteryLevel; }
    public void setBatteryLevel(double batteryLevel) { this.batteryLevel = batteryLevel; }
    
    public int getStatus() { return status; }
    public void setStatus(int status) { this.status = status; }
    
    public long getTimestamp() { return timestamp; }
    public void setTimestamp(long timestamp) { this.timestamp = timestamp; }
}

