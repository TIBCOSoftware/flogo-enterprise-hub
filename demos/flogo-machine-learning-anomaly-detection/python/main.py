from typing import Union
from fastapi import FastAPI
import numpy as np
from sklearn.ensemble import IsolationForest
import time
import logging

training_size = 10
training_abnormal_value_threshold = 5
data = []
training_flag = True
training_abnormal_value = 0
training_abnormal_value_count = 0

logging.basicConfig(level=logging.DEBUG)

def process(*values):
    for value in values:
        is_abnormal(value)
        time.sleep(1)    

def is_abnormal(value: float):
    global training_abnormal_value
    global training_abnormal_value_count
    global training_flag
    # Collect data for training and prediction, along with time-steps

    number_of_items = len(data)
    if (number_of_items < training_size):
        # Continue collecting training data if dataset is not sufficient
        data.append([value])
        logging.debug(f"Received {value} ... training")
        return False
    else:
        training_flag = False
        test_data = data.copy()
        test_data.append([value])
        # Convert to a NumPy array for Scikit-learn
        X = np.array(test_data)
        #print("X", X)

        #np.append(X, value)

        # Train an Isolation Forest model
        model = IsolationForest(contamination=0.01)
        model.fit(X)

        # Get the anomaly scores for the samples
        #scores = model.decision_function(X)
        #print("Anomaly scores:")
        #print(scores)

        # Predict anomalies
        pred = model.predict(X)

        # Anomalies are represented by -1
        anomalies = X[pred == -1]
        #anomaly_time_steps = [time_steps[i] for i in range(len(pred)) if pred[i] == -1]
        #print("Anomalies", anomalies)

        if (len(anomalies) == 0):
            logging.debug(f"Received {value} ... not abnormal")
            return False
        else: 
            abnormal_value = anomalies[0][0]
            if (abnormal_value == value):
                logging.debug(f"Received {value} ... !!! Abnormal !!! (Anomaly {anomalies})")
                return True
            else:
                logging.debug(f"Received {value} ... normal (abnormal value in training set {abnormal_value})")
                if (training_abnormal_value == abnormal_value):
                    training_abnormal_value_count += 1
                    if (training_abnormal_value_count >= training_abnormal_value_threshold):
                        logging.debug(f"Training value {abnormal_value} reached threshold ... replacing with {value}")
                        data.remove([abnormal_value])
                        data.append([value])        
                else:
                    training_abnormal_value = abnormal_value
                    training_abnormal_value_count = 0
                return False

app = FastAPI()
@app.get("/")
def read_root():
    return {"Hello": "World"}
@app.get("/isabnormal/{value}")
def get_isabnormal(value: float):
    AbnormalFlag = is_abnormal(value)
    print(f"API-value: {value} - TrainingFlag: {training_flag} - AbnormalFlag: {AbnormalFlag}")
    return {"abnormal_flag": AbnormalFlag, "training_flag": training_flag}

@app.get("/reset")
def reset():
    data.clear()
    return {"success": True}
@app.get("/config")
def config(in_training_size: int = 10, in_training_abnormal_value_threshold: int = 5):
    global training_size
    global training_abnormal_value_threshold
    training_size = in_training_size
    training_abnormal_value_threshold = in_training_abnormal_value_threshold
    return {"success": True}

if __name__ == "__main__":
    print("Minimum dataset needed for few shot training:", training_size)
    print("Number of times a training node is identified as abnormal before being replaced:", training_abnormal_value_threshold)
    process(73.0, 73.0, 72.0, 77.0, 75.0, 70.0, 73.0, 74.0, 77.0, 78.0, 72.0, 74.0, 75.0, 80.0, 90.0, 74.0, 75.0, 20.0, 72.0, 74.0)
