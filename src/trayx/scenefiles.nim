#[  T-RayX: a Nim ray tracing library
    Copyright (C) 2022 Matteo Baratto, Eleonora Gatti

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>. ]#

import std/[tables, streams, strutils, options, sets]
import shapes, geometry, basictypes, materials, pfm, transformation, cameras

const WHITESPACE* = ['\0', '\t', '\n', '\r', ' ']
const SYMBOLS* = ['(', ')', '[', ']', '<', '>', '*', ',']

type
  GrammarError* = object of CatchableError

#*************************************** SOURCE LOCATION *******************************************

type
  SourceLocation* = object 
    file_name* : string
    line_num* : int
    col_num* : int

proc newSourceLocation*(file_name : string = "", line_num = 0, col_num = 0): SourceLocation =
  result.file_name = file_name
  result.line_num = line_num
  result.col_num = col_num

proc `$`*(location : SourceLocation) : string =
    result = "Location: line "&($location.line_num)&", column "&($location.col_num)&". "

#******************************************** TOKEN ************************************************

type
  KeywordEnum* = enum
    NEW = 1,
    MATERIAL = 2,
    PLANE = 3,
    SPHERE = 4,
    DIFFUSE = 5,
    SPECULAR = 6,
    UNIFORM = 7,
    CHECKERED = 8,
    IMAGE = 9,
    IDENTITY = 10,
    TRANSLATION = 11,
    ROTATION_X = 12,
    ROTATION_Y = 13,
    ROTATION_Z = 14,
    SCALING = 15,
    CAMERA = 16,
    ORTHOGONAL = 17,
    PERSPECTIVE = 18,
    FLOAT = 19,
    AABOX = 20,
    CYLINDER = 21,
    LIGHTSOURCE = 22

const KEYWORDS = {"new": KeywordEnum.NEW,
              "material": KeywordEnum.MATERIAL,
              "plane": KeywordEnum.PLANE,
              "sphere": KeywordEnum.SPHERE,
              "diffuse": KeywordEnum.DIFFUSE,
              "specular": KeywordEnum.SPECULAR,
              "uniform": KeywordEnum.UNIFORM,
              "checkered": KeywordEnum.CHECKERED,
              "image": KeywordEnum.IMAGE,
              "identity": KeywordEnum.IDENTITY,
              "translation": KeywordEnum.TRANSLATION,
              "rotation_x": KeywordEnum.ROTATION_X,
              "rotation_y": KeywordEnum.ROTATION_Y,
              "rotation_z": KeywordEnum.ROTATION_Z,
              "scaling": KeywordEnum.SCALING,
              "camera": KeywordEnum.CAMERA,
              "orthogonal": KeywordEnum.ORTHOGONAL,
              "perspective": KeywordEnum.PERSPECTIVE,
              "float": KeywordEnum.FLOAT,
              "aabox": KeywordEnum.AABOX,
              "cylinder": KeywordEnum.CYLINDER,
              "light" : KeywordEnum.LIGHTSOURCE
              }.toTable
type
  TokenKind* = enum
    KeywordToken,
    IdentifierToken,
    StringToken,
    LiteralNumberToken,
    SymbolToken,
    StopToken
  Token* = ref TokenValue
  TokenValue* = object
    location*: SourceLocation
    case kind*: TokenKind
    of KeywordToken:
      keyword*: KeywordEnum
    of IdentifierToken:
      identifier* : string
    of StringToken:
      s* : string
    of LiteralNumberToken:
      value* : float
    of SymbolToken:
      symbol* : string
    of StopToken:
      flag* : bool

#***************************************** SCENE ***************************************************

type
  Scene* = object 
    world* : World
    materials* : Table[string, materials.Material]
    camera* : Option[cameras.Camera]
    float_variables* : Table[string, float]
    overridden_variables* : HashSet[string]

#***************************************************************************************************
#***************************************** INPUT STREAM ********************************************
#***************************************************************************************************

type
  InputStream* = object
    stream* : Stream
    location* : SourceLocation
    saved_char* : char
    saved_location* : SourceLocation
    tabulation* : int
    saved_token* : Option[Token]

proc newInputStream*(stream : Stream, file_name : string = "", tabulation = 4): InputStream =
  result.stream = stream
  result.location = newSourceLocation(file_name = file_name, line_num = 1, col_num = 1)
  result.saved_char = '\0'
  result.saved_location = result.location
  result.tabulation = tabulation
  result.saved_token = none(Token)

proc updatePos*(strm : var InputStream, ch : char) =
  if ch == '\0':
    return
  elif ch == ' ':
    strm.location.col_num = strm.location.col_num + 1
  elif ch == '\n':
    strm.location.line_num = strm.location.line_num + 1
    strm.location.col_num = 1
  elif ch == '\t':
    strm.location.col_num = strm.location.col_num + strm.tabulation
  else:
    strm.location.col_num = strm.location.col_num + 1

proc readChar*(strm : var InputStream) : char =
  if strm.saved_char != '\0':
  #if strm.stream.atEnd():
    result = strm.saved_char
    strm.saved_char = '\0'
  else:
    result = streams.readChar(strm.stream)
  strm.saved_location = strm.location
  strm.updatePos(result)

proc unreadChar*(strm : var InputStream, ch : char) =
  assert strm.saved_char == '\0'
  strm.saved_char = ch
  strm.location = strm.saved_location

proc skipWhitespacesAndComments*(strm : var InputStream) =
  ## Keep reading characters until a non-whitespace/non-comment character is found
  var ch = strm.readChar()
  while (ch in WHITESPACE) or (ch == '#'):
    if ch == '#':
      while not (strm.readChar() in ['\r', '\n', '\0']):
        discard
    ch = strm.readChar()
    if ch == '\0':
      return
  # Put the non-whitespace character back
  strm.unreadChar(ch)

proc parseStringToken*(strm : var InputStream, token_location : SourceLocation) : Token =
  var token : string = ""
  var ch : char
  while true:
    ch = strm.readChar()
    if ch == '"':
      break
    if ch == '\0':
      let error_string : string = "Unterminated string. Missing `\"` at position: row: "&intToStr(strm.location.line_num)&", column: "&intToStr(strm.location.col_num)
      raise newException(GrammarError, error_string)
    token = token & ch
  result = Token(location : token_location, kind : StringToken, s : token)

proc parseFloatToken*(strm : var InputStream, first_char : string, token_location : SourceLocation) : Token =
  var
    token = first_char
    ch : char
    value : float
  while true:
    ch = strm.readChar()
    if not (ch.isDigit() or ch == '.' or ch in ['e', 'E']):
      strm.unreadChar(ch)
      break
    token = token & ch
  try:
    value = token.parseFloat
  except ValueError:
      let error_string = "Location: row: "&intToStr(strm.location.line_num)&", column: "&intToStr(strm.location.col_num)&"\n"&($value)&"is an invalid floating-point number"
      raise newException(GrammarError, error_string)
  result = Token(location : token_location, kind : LiteralNumberToken, value : value) 

proc parseKeywordOrIdentifierToken*(strm : var InputStream, first_char : string, token_location : SourceLocation) : Token =
  var
    token = first_char
    ch : char
  while true:
    ch = strm.readChar()
    # Note that here we do not call "isAlpha" but "isAlphaNumeric": digits are ok after the first character ??????
    if not (ch.isAlphaNumeric() or ch=='_'):
      strm.unreadChar(ch)
      break
    token = token & ch
  try:
    # If it is a keyword, it must be listed in the KEYWORDS dictionary
    result = Token(location : token_location, kind : KeywordToken, keyword : KEYWORDS[token])
  except KeyError:
    # If we got KeyError, it is not a keyword and thus it must be an identifier
    result = Token(location : token_location, kind : IdentifierToken, identifier : token)

proc readToken*(strm : var InputStream) : Token =
  ## Read a token from the stream
  ## Raise `ParserError` if a lexical error is found.
  if not strm.saved_token.isNone:
    var res = strm.saved_token.get()
    strm.saved_token = none(Token)
    return res

  strm.skipWhitespacesAndComments()
  # At this point we're sure that ch does *not* contain a whitespace character
  var ch = strm.readChar()

  if ch == '\0':
    # No more characters in the file, so return a StopToken
    return Token(location : strm.location, kind : StopToken)

  # At this point we must check what kind of token begins with the "ch" character (which has been
  # put back in the stream with self.unread_char). First, we save the position in the stream
  
  let tkn_location = strm.location
  
  if ch in SYMBOLS:
    # One-character symbol, like '(' or ','
    result = Token(location : tkn_location, kind : SymbolToken, symbol : $ch)
  elif ch == '"':
    # A literal string (used for file names)
    result = strm.parseStringToken(tkn_location)
  elif ch.isDigit() or ch in ['+', '-', '.']:
    # A floating-point number
    result = strm.parseFloatToken(first_char = $ch, token_location = tkn_location)
  elif ch.isAlphaAscii() or ch == '_':
    # Since it begins with an alphabetic character, it must either be a keyword or a identifier
    result = strm.parseKeywordOrIdentifierToken(first_char = $ch, token_location = tkn_location)
  else:
    # We got some weird character, like '@` or `&`
    let error_string = "Invalid character: `"&ch&"` "&($strm.location)
    raise newException(GrammarError, error_string)

proc unreadToken*(strm : var InputStream, token : Token) =
  ## Make as if `token` were never read from `input_file`
  assert strm.saved_token.isNone
  strm.saved_token = some(token)

#***************************************************************************************************
#**************************************** EXPECT FUNCTION ******************************************
#***************************************************************************************************
# Read the token and check if the input is the expected one.

proc expectSymbol*(input_file: var InputStream, symbol: string) =
  ## Read a token from `input_file` and check that it matches `symbol`.
  let token : Token = input_file.readToken()
  if not (token.kind == SymbolToken) or not (token.symbol == symbol): # non certa che funzioni, c'è la keyword "of" ma da errori
    let error_string = $input_file.location&" Got: "&($token.symbol)&" instead of "&($symbol)
    raise newException(GrammarError, error_string)

proc expectKeywords*(input_file: var InputStream, keywords: seq[KeywordEnum]) : KeywordEnum=
  ## Read a token from `input_file` and check that it is one of the keywords in `keywords`.
  ## Return the keyword as a `KeywordEnum` object.
  let token : Token = input_file.readToken()
  if not (token.kind == KeywordToken):
    let error_string = $input_file.location&" Expected a keyword"
    raise newException(GrammarError, error_string)
  if not (token.keyword in keywords):
    let error_string = $input_file.location&" Expected one of the keywords [...] instead of "&($token.keyword) # sistemare messaggio di errore
    raise newException(GrammarError, error_string)
  result = token.keyword

proc expectNumber*(input_file: var InputStream, scene: Scene) : float =
  ## Read a token from `input_file` and check that it is either a literal number or a variable in `scene`.
  ## Return the number as a ``float``.
  let token : Token = input_file.readToken()
  if (token.kind == LiteralNumberToken):
    return token.value
  elif (token.kind == IdentifierToken):
    let variable_name : string = token.identifier
    if not (variable_name in scene.float_variables):
      let error_string : string = $input_file.location&" Unknown variable" # sistemare messaggio di errore
      raise newException(GrammarError, error_string)
    return scene.float_variables[variable_name]
  else:
    let error_string : string = $input_file.location&" Number expected" # sistemare messaggio di errore
    raise newException(GrammarError, error_string)

proc expectString*(input_file: var InputStream) : string =
  ## Read a token from `input_file` and check that it is a literal string.
  ## Return the value of the string (a ``str``).
  let token : Token = input_file.readToken()
  if not (token.kind == StringToken):
    let error_string = $input_file.location&"Expected a string"
    raise newException(GrammarError, error_string)
  return token.s

proc expectIdentifier*(input_file: var InputStream) : string =
  ## Read a token from `input_file` and check that it is an identifier.
  ## Return the name of the identifier.
  let token : Token = input_file.readToken()
  if not (token.kind == IdentifierToken):
    let error_string = $input_file.location&"Expected an identifier"
    raise newException(GrammarError, error_string)
  return token.identifier

#***************************************************************************************************
#********************************** PARSE FUNCTIONS ************************************************
#***************************************************************************************************

proc parseVector*(input_file: var InputStream, scene: Scene) : Vec =
  expectSymbol(input_file, "[")
  let  x : float = expectNumber(input_file, scene)
  expectSymbol(input_file, ",")
  let  y : float = expectNumber(input_file, scene)
  expectSymbol(input_file, ",")
  let  z : float = expectNumber(input_file, scene)
  expectSymbol(input_file, "]")  
  return Vec(x: x, y: y, z: z)

proc parsePoint*(input_file: var InputStream, scene: Scene) : Point =
  expectSymbol(input_file, "[")
  let  x : float = expectNumber(input_file, scene)
  expectSymbol(input_file, ",")
  let  y : float = expectNumber(input_file, scene)
  expectSymbol(input_file, ",")
  let  z : float = expectNumber(input_file, scene)
  expectSymbol(input_file, "]")  
  return Point(x: x, y: y, z: z)

proc parseColor*(input_file: var InputStream, scene: Scene) : Color =
  expectSymbol(input_file, "<")
  let  r : float = expectNumber(input_file, scene)
  expectSymbol(input_file, ",")
  let  g : float = expectNumber(input_file, scene)
  expectSymbol(input_file, ",")
  let  b : float = expectNumber(input_file, scene)
  expectSymbol(input_file, ">")
  return Color(r: r, g: g, b: b)

proc parsePigment*(input_file: var InputStream, scene: Scene) : Pigment =
  let keyword : KeywordEnum = expectKeywords(input_file, @[KeywordEnum.UNIFORM, KeywordEnum.CHECKERED, KeywordEnum.IMAGE])
  expectSymbol(input_file, "(")
  if keyword == KeywordEnum.UNIFORM:
    result = newUniformPigment(color = parseColor(input_file, scene))
  elif keyword == KeywordEnum.CHECKERED:
    let c1 : Color = parseColor(input_file, scene)
    expectSymbol(input_file, ",")
    let c2 : Color = parseColor(input_file, scene)
    expectSymbol(input_file, ",")
    # Magari aggiungere un if con un errore se non riceve un int!!!!!!!!!!!!!!!1
    let nstep : int = expectNumber(input_file, scene).toInt
    result = newCheckeredPigment(color1 = c1, color2 = c2, num_of_steps = nstep)
  elif keyword == KeywordEnum.IMAGE:
    let impf : Stream = openFileStream(expectString(input_file))
    let img : HdrImage = readPfmImage(impf)
    result = newImagePigment(image = img)
  else:
    assert false, "This line should be unreachable"
  expectSymbol(input_file, ")")

proc parseBRDF*(input_file: var InputStream, scene: Scene) : BRDF =
  let brdf_keyword : KeywordEnum = expectKeywords(input_file, @[KeywordEnum.DIFFUSE, KeywordEnum.SPECULAR])
  expectSymbol(input_file, "(")
  let pigment : Pigment = parsePigment(input_file, scene)
  expectSymbol(input_file, ")")
  if brdf_keyword == KeywordEnum.DIFFUSE:
    return newDiffuseBRDF(pigment = pigment)
  elif brdf_keyword == KeywordEnum.SPECULAR:
    return newSpecularBRDF(pigment = pigment)
  assert false, "This line should be unreachable"

proc parseMaterial*(input_file: var InputStream, scene: Scene) : (string, Material) = # (...) -> tuples
  let name = expectIdentifier(input_file)
  expectSymbol(input_file, "(")
  let brdf = parseBRDF(input_file, scene)
  expectSymbol(input_file, ",")
  let emitted_radiance = parsePigment(input_file, scene)
  expectSymbol(input_file, ")")
  return (name, Material(brdf_function: brdf, emitted_radiance: emitted_radiance))

proc parseTransformation*(input_file: var InputStream, scene: Scene) : Transformation =
  result = newTransformation()
  while true:
    let transformation_kw : KeywordEnum = expectKeywords(input_file, @[KeywordEnum.IDENTITY,
                                                         KeywordEnum.TRANSLATION,
                                                         KeywordEnum.ROTATION_X,
                                                         KeywordEnum.ROTATION_Y,
                                                         KeywordEnum.ROTATION_Z,
                                                         KeywordEnum.SCALING,])
    if transformation_kw == KeywordEnum.IDENTITY:
      discard # Do nothing (this is a primitive form of optimization!)
    elif transformation_kw == KeywordEnum.TRANSLATION:
      expectSymbol(input_file, "(")
      result = result * translation(parseVector(input_file, scene))
      expectSymbol(input_file, ")")
    elif transformation_kw == KeywordEnum.ROTATION_X:
      expectSymbol(input_file, "(")
      result = result * rotation_x(expectNumber(input_file, scene))
      expectSymbol(input_file, ")")
    elif transformation_kw == KeywordEnum.ROTATION_Y:
      expectSymbol(input_file, "(")
      result = result * rotation_y(expectNumber(input_file, scene))
      expectSymbol(input_file, ")")
    elif transformation_kw == KeywordEnum.ROTATION_Z:
      expectSymbol(input_file, "(")
      result = result * rotation_z(expectNumber(input_file, scene))
      expectSymbol(input_file, ")")
    elif transformation_kw == KeywordEnum.SCALING:
      expectSymbol(input_file, "(")
      result = result * scaling(parseVector(input_file, scene))
      expectSymbol(input_file, ")")
    # We must peek the next token to check if there is another transformation that is being
    # chained or if the sequence ends. Thus, this is a LL(1) parser.
    let next_kw : Token = input_file.readToken()
    if not (next_kw.kind == SymbolToken) or (next_kw.symbol != "*"):
      # Pretend you never read this token and put it back!
      input_file.unreadToken(next_kw)
      break

proc parseCamera*(input_file: var InputStream, scene: Scene) : Camera =
  expectSymbol(input_file, "(")
  let type_kw = expectKeywords(input_file, @[KeywordEnum.PERSPECTIVE, KeywordEnum.ORTHOGONAL])
  expectSymbol(input_file, ",")
  let transformation = parseTransformation(input_file, scene)
  expectSymbol(input_file, ",")
  let aspect_ratio = expectNumber(input_file, scene)
  expectSymbol(input_file, ",")
  let distance = expectNumber(input_file, scene)
  expectSymbol(input_file, ")")
  if type_kw == KeywordEnum.PERSPECTIVE:
    result = newPerspectiveCamera(distance = distance, aspect_ratio = aspect_ratio, transformation = transformation)
  if type_kw == KeywordEnum.ORTHOGONAL:
    result = newOrthogonalCamera(aspect_ratio = aspect_ratio, transformation = transformation)

proc parseLightSource*(input_file : var InputStream, scene : Scene) : PointLight =
  expectSymbol(input_file, "(")
  let position : Point = parsePoint(input_file, scene)
  expectSymbol(input_file, ",")
  let color : Color = parseColor(input_file, scene)
  expectSymbol(input_file, ",")
  let radius : float = expectNumber(input_file, scene)
  expectSymbol(input_file, ")")
  result = newPointLight(position, color, radius)

proc parseSphere*(input_file: var InputStream, scene: Scene) : Sphere =
  expectSymbol(input_file, "(")
  let material_name : string = expectIdentifier(input_file)
  if not scene.materials.hasKey(material_name):
    # We raise the exception here because input_file is pointing to the end of the wrong identifier
    let error_string = $input_file.location&" Unknown material "&($material_name)
    raise newException(GrammarError, error_string)
  expectSymbol(input_file, ",")
  let transformation = parseTransformation(input_file, scene)
  expectSymbol(input_file, ")")
  return newSphere(transformation = transformation, material = scene.materials[material_name])

proc parsePlane*(input_file: var InputStream, scene: Scene) : Plane =
  expectSymbol(input_file, "(")
  let material_name : string = expectIdentifier(input_file)
  if not scene.materials.hasKey(material_name):
    # We raise the exception here because input_file is pointing to the end of the wrong identifier
    let error_string = $input_file.location&"Unknown material "&($material_name)
    raise newException(GrammarError, error_string)
  expectSymbol(input_file, ",")
  let transformation = parseTransformation(input_file, scene)
  expectSymbol(input_file, ")")
  return newPlane(transformation = transformation, material = scene.materials[material_name])

proc parseAABox*(input_file: var InputStream, scene: Scene): AABox =
  expectSymbol(input_file, "(")
  let material_name : string = expectIdentifier(input_file)
  if not scene.materials.hasKey(material_name):
    # We raise the exception here because input_file is pointing to the end of the wrong identifier
    let error_string = $input_file.location&" Unknown material "&($material_name)
    raise newException(GrammarError, error_string)
  expectSymbol(input_file, ",")
  let transformation = parseTransformation(input_file, scene)
  expectSymbol(input_file, ")")
  return newAABox(transformation = transformation, material = scene.materials[material_name])

proc parseCylinder*(input_file: var InputStream, scene: Scene): Cylinder =
  expectSymbol(input_file, "(")
  let material_name : string = expectIdentifier(input_file)
  if not scene.materials.hasKey(material_name):
    # We raise the exception here because input_file is pointing to the end of the wrong identifier
    let error_string = $input_file.location&" Unknown material "&($material_name)
    raise newException(GrammarError, error_string)
  expectSymbol(input_file, ",")
  let transformation = parseTransformation(input_file, scene)
  expectSymbol(input_file, ")")
  return newCylinder(transformation = transformation, material = scene.materials[material_name])

proc parseScene*(input_file: var InputStream, variables: Table[string, float] = initTable[string, float]()) : Scene =
  ## Read a scene description from a stream and return a `.Scene` object
  result.float_variables = variables
  for k in variables.keys:
    result.overridden_variables.incl(k)
  result.world = newWorld()
  while true:

    let what = input_file.readToken()    
    if what.kind == StopToken:
      break
    if not (what.kind == KeywordToken):
      let error_string = $input_file.location&" Expected a keyword."
      raise newException(GrammarError, error_string)


    case what.keyword
    of KeywordEnum.FLOAT:
      let variable_name : string = expectIdentifier(input_file)
      # Save this for the error message
      let variable_loc = input_file.location
      expectSymbol(input_file, "(")
      let variable_value = expectNumber(input_file, result)
      expect_symbol(input_file, ")")
      if (variable_name in result.float_variables) and not (variable_name in result.overridden_variables):
        let error_string = $variable_loc&" Variable "&($variable_name)&" cannot be redefined."
        raise newException(GrammarError, error_string) 
      if not result.overridden_variables.contains(variable_name):
        # Only define the variable if it was not defined by the user *outside* the scene file
        # (e.g., from the command line)
        result.float_variables[variable_name] = variable_value
    of KeywordEnum.CAMERA:
      if not result.camera.isNone:
        let error_string = $what.location&"You cannot define more than one camera"
        raise newException(GrammarError, error_string)
      result.camera = some(parseCamera(input_file, result))
    of KeywordEnum.MATERIAL:
      var (name, material) = parseMaterial(input_file, result)
      result.materials[name] = material  
    of KeywordEnum.LIGHTSOURCE:
      result.world.point_lights.add(parseLightSource(input_file, result))  
    of KeywordEnum.SPHERE:
      result.world.shapes.add(parseSphere(input_file, result))
    of KeywordEnum.PLANE:
      result.world.shapes.add(parsePlane(input_file, result))
    of KeywordEnum.AABOX:
      result.world.shapes.add(parseAABox(input_file, result))
    of KeywordEnum.CYLINDER:
      result.world.shapes.add(parseCylinder(input_file, result))
    else:
      let error_string = $input_file.location&" Invalid keyword."
      raise newException(GrammarError, error_string)   
