# Set-DummyAD Attribution

AMRL directory population functionality derives concepts and logic from
Set-DummyAD by BOAScripts.

Repository:
https://github.com/BOAScripts/Set-DummyAD

License:
MIT License

## Relationship to AMRL

AMRL does not execute the original Set-DummyAD code.

The original project inspired the following AMRL capabilities:

- OU generation
- Group generation
- Department modelling
- User population
- AGDLP implementation
- Share creation

## AMRL Enhancements

AMRL introduces significant architectural changes:

- Azure VM Run Command execution
- Bicep integration
- Embedded script deployment
- names.csv delivery through deployment parameters
- Idempotent object creation
- Stable manager assignment
- Parameterized departments
- Parameterized user counts
- Existing user remediation
- Automated lab deployment integration

See the AMRL project documentation for implementation details.