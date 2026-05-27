from pytest_bdd import given, when, then, scenarios

scenarios("../example.feature")


@given("the system is initialized")
def system_initialized():
    # Setup: initialize your system under test
    raise NotImplementedError("Replace with real step definition")


@when("the user performs the primary action")
def user_performs_action():
    # Action: trigger the behavior under test
    raise NotImplementedError("Replace with real step definition")


@then("the expected outcome is observed")
def expected_outcome():
    # Assert: verify the expected result
    raise NotImplementedError("Replace with real step definition")
