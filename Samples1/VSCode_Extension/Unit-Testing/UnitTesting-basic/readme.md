# Unit Testing


## Description

Unit testing is a technique where individual components or flows of an application are tested in isolation. With unit testing, you can monitor the health of your application and detect errors in individual flows or activity levels. While designing an application with multiple flows and activities, it becomes cumbersome to detect runtime errors at the flow and activity levels. Using unit testing the errors at micro level are easily handled.

## Prerequisites

* You need go version=go1.20.12 or above, to be installed on your machine. For information about go installation on Windows, Mac, or Linux, see https://go.dev/doc/install" as a pre-req before running app locally.


## Creating Assertions

An assertion is a logical expression that evaluates to a boolean value. The expected versus actual output is compared by using an assertion expression. For the passed assertion, the expression evaluates to true.We can add one or more assertions to activity, errorhandler and flow output. You cannot create assertions for the activities that do not return the output. 

1. Flow output - Flow output is the output generated for the given flow for the given set of inputs. Flow output can have one or more assertions. To add assertions to the flow output, the output must be defined. Then only you can see the assertions options in flow output. 

![Flow Output](../../images/Unit-Testing/UnitTesting-Sample/flowoutput.png)


2. Assert on Error - You can add assertions to the flow output to verify that the flow produces the correct data by comparing the actual output against predefined assertions. Assert on Error adds an assertion for the flow designed with error. To make the assertion pass without using error handler we can add flow output assertion to the flow output. 

![Assert on Error](../../images/Unit-Testing/UnitTesting-Sample/assertonerror.png)

3. Assert On Output - To compare the actual vs. expected output, you can add multiple assertions on an activity, flow output, or error handler. We can use functions while adding assertions. This option is only visible for the activities having output.

![Assert on Output](../../images/Unit-Testing/UnitTesting-Sample/assertonoutput.png)

## Other Modes

1. Skip Execution - We can use skip an activity in unit testing if the activity does not have any output. 


2. Execute Default - When execute default is selected, it does not affect any unit testing execution. We can also use this option to reset the configuration.

## Mocking Data
In unit testing, you can mock the data for the unit that is being tested. This is useful during unit testing so that the external dependencies are no longer a constraint to the unit under test. Using mock data, the dependencies are replaced by closely controlled replacements that simulate the behavior of the real ones.

You can use the mock data for the activities that have an output. Expressions and functions are not evaluated in the values given to mock outputs, the input provided is passed as-is.

In unit testing, you can either use assertions or mock data to test the activities.

1. Mock Error - Use mock exceptions for an activity to find out whether the exception handling is being done correctly or not. This option is only visible for the activities having output. Add mock error to pass the dummy error message to make the assertion pass.

![Mock Error](../../images/Unit-Testing/UnitTesting-Sample/mockerror.png)

2. Mock Outputs - You can use the mock data for the activities that have an output. Data mocks are fake data that is used to simulate real data in a controlled environment. Add mock output to pass dummy outputs to make the assertion pass.

![Mock Output](../../images/Unit-Testing/UnitTesting-Sample/mockoutput.png)

## Defining Flow Input
For a particular activity that has a flow input configured in the actual process, you must assign the flow input parameters before you run a test case. You can add separate test cases for each flow input.

## Import the sample

The sample app gets the zip code of the customer for the given customer id. Added the assertions and mock for this sample app covering assert on error, assert on output, mock error and mock output.

In the given application if we pass the correct id in the flow input that would redirect to the correct url passed in invoke rest service, the test case would pass and correct zip code will be displayed and this we can assert using assert an output.

If we pass the id in the flow input which doesn't exist i:e that wouldn't redirect to the right url passed in invoke rest service, the test case would fail as it would not get the zip code of the customer and this we can assert using assert on error, displaying the error message "Invalid path '.address.zipcode'. path not found." configured in the assertion.

If the invoke rest service is down or inaccessible and we want to mock the data and get the output, using mocking of data though the invoke rest will not be called, but we will still get the desired result from the data we have mocked.




1. Download the UnitTesting.flogo and UnitTesting.flogotest file.

2. Put these files in VSCode workspace

![Unit Testing files in VSCode workspace](../../images/Unit-Testing/UnitTesting-Sample/import.png)



### Run the application

1. Click on the UnitTesting.flogotest

![.flogotest file](../../images/Unit-Testing/UnitTesting-Sample/testing.png)

2. Click on the testing icon in VSCode on the left side. Expand the app name and the test suite and click on the run test button to see the test results.

![Testing icon](../../images/Unit-Testing/UnitTesting-Sample/testing1.png)




## Outputs

After clicking on run test button, a test result file will generate under test-results folder in your VScode workspace.

1. Assert on Error

![Sample Response](../../images/Unit-Testing/UnitTesting-Sample/assertonerrorresult.png)

2. Assert On Output

![Sample Response](../../images/Unit-Testing/UnitTesting-Sample/assertonoutputresult.png)

3. Mock Error

![Sample Response](../../images/Unit-Testing/UnitTesting-Sample/mockerrorresult.png)

4. Mock Outputs

![Sample Response](../../images/Unit-Testing/UnitTesting-Sample/mockoutputresult.png)


## Notes & Conclusion

1. One can run unit testing at any phase of the development cycle to verify whether activities in the process are working as expected.

2. Using testing processes in the development stage (before you push the application to the production environment), helps detect errors and identify issues at an early stage.

