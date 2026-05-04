package encrypt

import (
	"fmt"
	"testing"

	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
)

const plaintext = `This is my message`

const ciphertext = `
-----BEGIN PGP MESSAGE-----

wYwD6bYhtpRVcqQBBACeYy5J8/F7nIdJNLaPXnoXdg1tpGE3yKJoHyq4B0z0wh2L
ZdVPgdMJ1+998H5vrBJk/ybFsFVIE26D2qAXQbviIKGMIDvW5Uu/ahjh/aSJLV56
jYiJTZUwE0GweTBQ3YYYsaOSQgJWecfAsf8ChkwBvLRbxqFsKlwNvBiv8enp69JD
Acvzw1TA1ct6Td6WWoIGz1Pv3CI/mhGSmfo1KrPV2XB1ayzYMOR8L7ExuHb6fqhw
LXXy3JsYO1F6fLbrvq2gReQAWQ==
=TUbm
-----END PGP MESSAGE-----`

const pubKeyArmored = `-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: Keybase OpenPGP v2.1.17
Comment: https://keybase.io/crypto

xo0EabgxNAEEALow5SvP3WpF9zb3nJrFhbf5POJ9Kpl8sYOa+BbWL2Bdye2oX1rn
Slvyauo9lOH5w9MSmZT/vSGqOhgGNs9lYbIh87nZTuZ5chHPTUSJSZS/6ynaIhSB
binbv2cgY1n26KvXsQ67fMNjfzHHKb39uA+IMqNIiDRlSQ/k7lDOikH7ABEBAAHN
GSA8bWFyay5tdXNzZXR0QHRpYmNvLmNvbT7CtAQTAQoAHgUCabgxNAIbLwMLCQcD
FQoIAh4BAheAAxYCAQIZAQAKCRAllQQUorcVEg4+A/96kCzHukDO8VCvylzS7FLB
coj58eHRUdhrOo/NDgNwcxoyUXFi7HyozjF5iP5hbiGK67C18wTz2UTDUph5OUrW
cmDpsx5vzxTkSPWIJZUoBkedOEggf8GJcnWreaWw5atuqDY+wrQVJRU23qQ/VrO/
XDCG6T6kR01W6dL2RhTHXc6NBGm4MTQBBAC+9FMIGObejwZY1HK4FWJs7Hc0zLwi
eWR9p00D2bnzal2U7U0AGfFcoReM/Zc5w3KgGrTvmdBthHNumWfgnKLaAz4thDvH
xD+kJlRtTaY3LK5z3ZCf3D6QzAbk7TB0ilUXcPTb3EgIVFO9F/3mP9YHai0hE9ny
IF+xo7nNqhYPaQARAQABwsCDBBgBCgAPBQJpuDE0BQkPCZwAAhsuAKgJECWVBBSi
txUSnSAEGQEKAAYFAmm4MTQACgkQ6bYhtpRVcqRV8gP/exCW+AKk7x59/nRWn1LN
PzSoLtUPXbSRpM6tDN+79rEXEvN+J3VswmWGKkKafg2r7RhqhrCpn0yWmf47DD2p
IVsC1fIRwnazwsS2V1tdvEUagy/9U6fsoJK8JOGBI3nY8gHn0x+J/8Dz2bWJZqjj
yr3SbNw6E4fdF/J9nP3lmVlA+wQAtP0goUugvgNd95VP/HDPVdd+xnQEo0tgiiij
OkTAv08ap0au8+uzz0fAJY0sqhRcAFCZxY9XVWumFUuy8MRpjZdyZHka3HA+w6GN
R4qTqOeUVSYRuo0khwRyyr8LITEjR61c9LCWqAm2onRt/KtG4zKpp4OGBhGI/Qba
uLzL9yjOjQRpuDE0AQQA1/nwyItY2qmL25WcQKaSQ7Yv3K0FVa7O0VGcezYdhJ+/
Z4PdYC8vH33duYCt1TXDeUC+Z0axuhTYIYAmw0Nvnr55B0MF7P+DiGKqGIatHwAJ
f2us8D4MmICD+Us/QWX2F129Yw+J5pbz/dTIjaEqyk8H6qPHTsCNyNWyboUjPf8A
EQEAAcLAgwQYAQoADwUCabgxNAUJA8JnAAIbLgCoCRAllQQUorcVEp0gBBkBCgAG
BQJpuDE0AAoJEKqpNnWXVPDsdr8D/3nLfQrY/57Hj8iycK40lp8e8UR4OjjO3AN5
NM2G7z94jDQ6k6gF1CeDR9+/hhVwwW+HJDoHMn1aC6MRLmox2yRD1Q7VmnFxcFd2
LVARoKoIlZ7dSpcz45oyPOrIGIf7df+XL+7A4YdiIgHMhj2ZsKAfcAhNo1QlHv22
YQMC20K91I8EALV71qIcwx/4EY4oFna5jHPITY9XUIUJEVkD74vDVJ78IjAEnU1Z
b9nqXdu8hrp8DXn+RAaQ26b0ahWKVDGCHykJlb2uV00yFENxOELyD1Jaj+b24Q4T
lc22RU4vFCjbFbi5D/pD5l6B2U9JC9WnmcrnJrzVXdTr+68iRaV+06tb
=K9s3
-----END PGP PUBLIC KEY BLOCK-----`

const privKeyArmored = `-----BEGIN PGP PRIVATE KEY BLOCK-----
Version: Keybase OpenPGP v2.1.17
Comment: https://keybase.io/crypto

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
=5aKj
-----END PGP PRIVATE KEY BLOCK-----`

func TestRegister(t *testing.T) {

	ref := activity.GetRef(&MyActivity{})
	act := activity.Get(ref)

	assert.NotNil(t, act)
}

func TestEval(t *testing.T) {

	act := &MyActivity{}

	tc := test.NewActivityContext(act.Metadata())

	tc.SetInput("publickey", pubKeyArmored)
	tc.SetInput("plaintext", plaintext)
	done, err := act.Eval(tc)
	if !done {
		fmt.Println(err)
	}

	assert.True(t, done)
	var output = fmt.Sprint(tc.GetOutput("ciphertext"))
	fmt.Println("Output    : ", string(output))

}
