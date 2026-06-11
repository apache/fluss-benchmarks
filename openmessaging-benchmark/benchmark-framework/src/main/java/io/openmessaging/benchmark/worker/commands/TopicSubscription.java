/*
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package io.openmessaging.benchmark.worker.commands;

public class TopicSubscription {
    public String topic;
    public int subId;
    public String subscription;
    public int partitionsPerTopic;
    public int partitionsPerSubscription;

    public TopicSubscription() {}

    public TopicSubscription(
            String topic,
            int subId,
            String subscription,
            int partitionsPerTopic,
            int partitionsPerSubscription) {
        this.topic = topic;
        this.subId = subId;
        this.subscription = subscription;
        this.partitionsPerTopic = partitionsPerTopic;
        this.partitionsPerSubscription = partitionsPerSubscription;
    }

    @Override
    public String toString() {
        return "TopicSubscription{"
                + "topic='"
                + topic
                + '\''
                + ", subId="
                + subId
                + '\''
                + ", subscription='"
                + subscription
                + '\''
                + ", partitionsPerTopic="
                + partitionsPerTopic
                + ", partitionsPerSubscription="
                + partitionsPerSubscription
                + '}';
    }
}
