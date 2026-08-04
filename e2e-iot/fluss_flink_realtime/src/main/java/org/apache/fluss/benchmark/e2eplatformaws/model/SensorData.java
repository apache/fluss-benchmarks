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
import java.util.Objects;

/**
 * Sensor data record used in the demo. This mirrors the schema that was used in the
 * RealtimeDataPlatform example (flattened metadata for simplicity).
 */
public class SensorData implements Serializable {
    private String sensorId;
    private String sensorType;
    private String location;
    private double temperature;
    private double humidity;
    private double pressure;
    private double batteryLevel;
    private String status;
    private Instant eventTime;
    private MetaData metadata;

    public SensorData() {}

    public SensorData(
            String sensorId,
            String sensorType,
            String location,
            double temperature,
            double humidity,
            double pressure,
            double batteryLevel,
            String status,
            Instant eventTime,
            MetaData metadata) {
        this.sensorId = sensorId;
        this.sensorType = sensorType;
        this.location = location;
        this.temperature = temperature;
        this.humidity = humidity;
        this.pressure = pressure;
        this.batteryLevel = batteryLevel;
        this.status = status;
        this.eventTime = eventTime;
        this.metadata = metadata;
    }

    public String getSensorId() {
        return sensorId;
    }

    public void setSensorId(String sensorId) {
        this.sensorId = sensorId;
    }

    public String getSensorType() {
        return sensorType;
    }

    public void setSensorType(String sensorType) {
        this.sensorType = sensorType;
    }

    public String getLocation() {
        return location;
    }

    public void setLocation(String location) {
        this.location = location;
    }

    public double getTemperature() {
        return temperature;
    }

    public void setTemperature(double temperature) {
        this.temperature = temperature;
    }

    public double getHumidity() {
        return humidity;
    }

    public void setHumidity(double humidity) {
        this.humidity = humidity;
    }

    public double getPressure() {
        return pressure;
    }

    public void setPressure(double pressure) {
        this.pressure = pressure;
    }

    public double getBatteryLevel() {
        return batteryLevel;
    }

    public void setBatteryLevel(double batteryLevel) {
        this.batteryLevel = batteryLevel;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public Instant getEventTime() {
        return eventTime;
    }

    public void setEventTime(Instant eventTime) {
        this.eventTime = eventTime;
    }

    public MetaData getMetadata() {
        return metadata;
    }

    public void setMetadata(MetaData metadata) {
        this.metadata = metadata;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) {
            return true;
        }
        if (!(o instanceof SensorData)) {
            return false;
        }
        SensorData that = (SensorData) o;
        return Double.compare(that.temperature, temperature) == 0
                && Double.compare(that.humidity, humidity) == 0
                && Double.compare(that.pressure, pressure) == 0
                && Double.compare(that.batteryLevel, batteryLevel) == 0
                && Objects.equals(sensorId, that.sensorId)
                && Objects.equals(sensorType, that.sensorType)
                && Objects.equals(location, that.location)
                && Objects.equals(status, that.status)
                && Objects.equals(eventTime, that.eventTime)
                && Objects.equals(metadata, that.metadata);
    }

    @Override
    public int hashCode() {
        return Objects.hash(
                sensorId,
                sensorType,
                location,
                temperature,
                humidity,
                pressure,
                batteryLevel,
                status,
                eventTime,
                metadata);
    }

    @Override
    public String toString() {
        return "SensorData{"
                + "sensorId='"
                + sensorId
                + '\''
                + ", sensorType='"
                + sensorType
                + '\''
                + ", location='"
                + location
                + '\''
                + ", temperature="
                + temperature
                + ", humidity="
                + humidity
                + ", pressure="
                + pressure
                + ", batteryLevel="
                + batteryLevel
                + ", status='"
                + status
                + '\''
                + ", eventTime="
                + eventTime
                + ", metadata="
                + metadata
                + '}';
    }

    /** Nested metadata payload. */
    public static class MetaData implements Serializable {
        private String manufacturer;
        private String model;
        private String firmwareVersion;
        private double latitude;
        private double longitude;

        public MetaData() {}

        public MetaData(
                String manufacturer,
                String model,
                String firmwareVersion,
                double latitude,
                double longitude) {
            this.manufacturer = manufacturer;
            this.model = model;
            this.firmwareVersion = firmwareVersion;
            this.latitude = latitude;
            this.longitude = longitude;
        }

        public String getManufacturer() {
            return manufacturer;
        }

        public void setManufacturer(String manufacturer) {
            this.manufacturer = manufacturer;
        }

        public String getModel() {
            return model;
        }

        public void setModel(String model) {
            this.model = model;
        }

        public String getFirmwareVersion() {
            return firmwareVersion;
        }

        public void setFirmwareVersion(String firmwareVersion) {
            this.firmwareVersion = firmwareVersion;
        }

        public double getLatitude() {
            return latitude;
        }

        public void setLatitude(double latitude) {
            this.latitude = latitude;
        }

        public double getLongitude() {
            return longitude;
        }

        public void setLongitude(double longitude) {
            this.longitude = longitude;
        }

        @Override
        public String toString() {
            return "MetaData{"
                    + "manufacturer='"
                    + manufacturer
                    + '\''
                    + ", model='"
                    + model
                    + '\''
                    + ", firmwareVersion='"
                    + firmwareVersion
                    + '\''
                    + ", latitude="
                    + latitude
                    + ", longitude="
                    + longitude
                    + '}';
        }

        @Override
        public boolean equals(Object o) {
            if (this == o) {
                return true;
            }
            if (!(o instanceof MetaData)) {
                return false;
            }
            MetaData metaData = (MetaData) o;
            return Double.compare(metaData.latitude, latitude) == 0
                    && Double.compare(metaData.longitude, longitude) == 0
                    && Objects.equals(manufacturer, metaData.manufacturer)
                    && Objects.equals(model, metaData.model)
                    && Objects.equals(firmwareVersion, metaData.firmwareVersion);
        }

        @Override
        public int hashCode() {
            return Objects.hash(manufacturer, model, firmwareVersion, latitude, longitude);
        }
    }
}
