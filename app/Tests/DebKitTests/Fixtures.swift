import Foundation

/// Base64 of a deb built by real dpkg-deb (control.tar.xz / data.tar.xz)
/// with an Sileo-style control stanza for a fictional iOS app package.
let fixtureXZBase64 = "ITxhcmNoPgpkZWJpYW4tYmluYXJ5ICAgMTc5MzE2MzQxNiAgMCAgICAgMCAgICAgMTAwNjQ0ICA0ICAgICAgICAgYAoyLjAKY29udHJvbC50YXIueHogIDE3OTMxNjM0MTYgIDAgICAgIDAgICAgIDEwMDY0NCAgNTY0ICAgICAgIGAK/Td6WFoAAATm1rRGBMDxA4BQIQEWAAAAAAAAAM6rZuDgJ/8B6V0AFwu8HH0BlcAdSj55FcLMJqNjFmeNgVQKf+Xp5aY/JbdC99siE5ya56bDeAiKwh8H4xqt2Ph4uy62Xt6cGRSW31LWszmV5Nqy3nZsayCiIalzsAXO7lotLzpx+hj1IfE5gbX7mf710+KLaejJq79oNyB2mhT2JGQbkdAN4SQTx9Iodw8nO7HhbLy3Wxsf7XoWwfoHj2MAvzWztQ5tnYBr+cNHXUicGnaM4rpfsN54xYsxrY9lAr/0r97FHFYvzDDd+lgFv+GwjUQd9xjB9Dc5JfrRleA/OnjRg7aHuzsSeuGNnh4MXtdoa1DeELU/s7HZAYd2t9FXKgSEotycYqfQLp/1mT6GOIFugF2nmk63UoUD4hM6c6X0keYPHcbl/HBvi548WQdxYcPfIJwSzoVLKVEllQ0hZl2RTQCBYJYuoST2mWexfoFWveqF0N4F04AWXq0WDOadFihCzHobXD670zNbBqPEib6+0vcwZr3n1Q2cXQq90Bt9fzXBWMVqkhKa43LLRpz8WBo82SaJhndz95e5fxBTRFk14zulJYWYzIZZjmmZVrtmxxQEbxFSbTTEko9Pg72glc/sEehLu19sz9F0IbVo9OjQQxz+Jh7kRtyiZyr+bTsdmimJDgmobN3nRuLZd3en9LkAAAAAAG59cuF48GOTAAGNBIBQAACQ7R4VscRn+wIAAAAABFlaZGF0YS50YXIueHogICAgIDE3OTMxNjM0MTYgIDAgICAgIDAgICAgIDEwMDY0NCAgNDEyICAgICAgIGAK/Td6WFoAAATm1rRGBMDbAoBQIQEWAAAAAAAAAAjQoyLgJ/8BU10AFwu8HH0BlcAdSj55FcLMJqNjFmeNgVQKf+Xp5aY/JbdC99siE5ya56bDeAiKwh8H4xqt2Ph4uy+WWxUNjC5VWozPxCUV0rcussUu1eA75ybVqbaMi2JEwC8+8QD0VqhDoGxMklFnT069P0NgA2fUcqXt1PytbbcpUvnqG3KjVHRowfiiDkOUw6/HPHxxmbBI7Krmpy1QrjdijKLwSrfejThDKiAsYk2rfKHAxtSIpwDI5zjeFsnmc4EAeEjwN/HsQodx+U8n+sA6OzUpvFkZteWXCOVIShCYGngUkSJY0jHO0+HKRyHDQ1RlMzik3HGzPwEkpXP0yK08Gp6gnkvp4zWwlDQv3aR1SDzMVj8Xr9/Z7cqF3wi8t8bIc6efgyjuhrrCMP2oo8ZhdOfPf0udfVeR6XjhC/0pyJqEk9b1KmdKdmijL8ht4w4DsaqUHn0rE5gAAAD7uHSpzt9OpAAB9wKAUAAAlzbnMLHEZ/sCAAAAAARZWg=="

/// The same package built with gzip members instead of xz.
let fixtureGZBase64 = "ITxhcmNoPgpkZWJpYW4tYmluYXJ5ICAgMTc5MzE2MzQxNiAgMCAgICAgMCAgICAgMTAwNjQ0ICA0ICAgICAgICAgYAoyLjAKY29udHJvbC50YXIuZ3ogIDE3OTMxNjM0MTYgIDAgICAgIDAgICAgIDEwMDY0NCAgNDg4ICAgICAgIGAKH4sIAAAAAAACA+3SS2vcMBAA4D3rV8yxC1mtH/tITRsa6CE9NA3d0rvWHq/FWpKRZNyW0t/esTckpNDmtIXAfNjIntHD0lguZ2eXkO16PbXkz3Z6TtfZNsmTJMvH+HabpDNYz/6DPkTlAWbeufivfs/lXyi5LJ2N3rVnrv9mtfpb/dMkWz2tf5rmY/0Trv/Z3anyqA5YwBBks1f2IC0OEb3Jxa0yFL/F4Qu9Qi6+og/a2QJymfzaY1TpIr0U175sdMQy9p56665xFl1YKG82K/FRaRvpRl/AjRqOaOFNM7Xv8JsyXYtyCFdiR8OnmceVtFWtuPPaeR2/F+C6MUWhD5Yq1bZYLXb6By01/jbiPXZoq1CAcXvdYuj3IXoVEV5dvYVEvpYb+sHmF9B5rNGjLbF1qkI/5TOZyXwOPwFp2qOOF1BrbwblT8PTlUzm9CW4eFjlaT4b85+xdMac0g9nOIacpa8LpdfdaW/XEO93B2j6VkXnoaZbf9oJStZ92y5qVOM5Vo9dKwz6YClSe2cgNijg4F1vK+i7aXh0fdlIAXTt+q5zPgY6DNqipbSlF0V9aRxNd5Dixhnspno3MXahWC4f67C8r7yYMcYYY4wxxhhjjDHGGGOMMcYYY4yxF+M3S+oFkgAoAABkYXRhLnRhci5neiAgICAgMTc5MzE2MzQxNiAgMCAgICAgMCAgICAgMTAwNjQ0ICAzNjQgICAgICAgYAofiwgAAAAAAAID7ZhNT4MwHIc5+ynI7tIXWnpBFhMvJupFv0BhNasBSko35dvLmF5InJmTF93/ubRQbk9/8CsB8gYHtwjOu7GlP3ZzwqnAIcY03N0XAhPP594IbGonre971hh36Lnv1v8oAdpKi2bmn2AmwP+I/l9SNCv/BEcM/I/q/7qqcp1Jp01Zo6n9h5xQ8D+d/wf1+qRsEciqQlP45xEH/zPxf1s+m6Bdq90p/iPGvvbPWc+/iGj7/cfgf3Di5VuR+1tl61b81YIEeLFM4k53Eq905lASo/3lhQecYf4/5ie+/w/mn4b9/BMO+R+FKpeZWpt8paxfyGx9aSDmZ5n/O51aaZshzoHH9z/KBIb+N4n/e5PqXD1u0tpZ6RSaxD/nAs7/8/B/05Sy0Nl+Wauf/Bs42j8l7RYA//P0/9kNV02u01/qf7TnP2Q7/9D/xu1/nVGofwAAAAAAAAAAAP+Sd+QHdaEAKAAA"

/// Test data and archive-building helpers.
enum Fixtures {

    static var debXZ: Data {
        guard let d = Data(base64Encoded: fixtureXZBase64) else {
            fatalError("corrupt xz fixture")
        }
        return d
    }

    static var debGZ: Data {
        guard let d = Data(base64Encoded: fixtureGZBase64) else {
            fatalError("corrupt gz fixture")
        }
        return d
    }

    /// Builds an ar archive from members, applying the same 60-byte header
    /// layout and even-byte padding rules dpkg writes.
    static func ar(_ members: [(name: String, data: Data)]) -> Data {
        var out = Data(Array("!<arch>\n".utf8))
        for member in members {
            out.append(arHeader(name: member.name, size: member.data.count))
            out.append(member.data)
            if member.data.count % 2 == 1 {
                out.append(0x0A)
            }
        }
        return out
    }

    /// One padded 60-byte member header.
    private static func arHeader(name: String, size: Int) -> Data {
        var header = Data()
        let fields: [(String, Int)] = [
            (name, 16),
            ("0", 12),
            ("0", 6),
            ("0", 6),
            ("100644", 8),
            (String(size), 10),
        ]
        for (value, width) in fields {
            header.append(Data(value.padding(toLength: width, withPad: " ", startingAt: 0).utf8))
        }
        header.append(Data("\u{60}\n".utf8))
        precondition(header.count == 60)
        return header
    }
}
