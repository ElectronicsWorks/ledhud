
// Sparkfun 9DOF Razor IMU AHRS
// 9 Degree of Freedom Attitude and Heading Reference System
// Firmware v1.1gke
//
// Released under Creative Commons License
// Based on ArduIMU v1.5 by Jordi Munoz and William Premerlani, Jose Julio and Doug Weibel
// Substantially rewritten by Prof. G.K. Egan 2010

// Axis definition (positive): 
// X axis forward (to the FTDI connector)
// Y axis  right 
// and Z axis down.
// Pitch up around Y
// Roll right around X
// and Yaw clockwise around Z

/* 
 Hardware version - v13
 	
 ATMega328@3.3V w/ external 8MHz resonator
 High Fuse DA
 Low Fuse FF
 	
 ADXL345: Accelerometer
 HMC5843: Magnetometer
 LY530:	Yaw Gyro
 LPR530:	Pitch and Roll Gyro
 
 Programmer : 3.3v FTDI
 Arduino IDE : Select board  "Arduino Duemilanove w/ATmega328"
 This code works also on ATMega168 Hardware
 */
 
 /*
 For TierTex display
 */

#include <Wire.h>
#include <EEPROM.h>

#define TRUE 1
#define FALSE 0

#define EEPROMBase 128  // keep clear of location zero

// ADXL345 Sensitivity(from datasheet) => 4mg/LSB   1G => 1000mg/4mg = 256 steps
#define GRAVITY 256

// LPR530 & LY530 Sensitivity (from datasheet) => (3.3mv at 3v) at 3.3v: 3mV/º/s, 3.22mV/ADC step => 0.93
// Tested values : 0.92
#define GyroToDegreesSec 0.92 // deg/sec
#define GyroToRadianSec 0.016057 // radian/sec 

/*#define Kp_RollPitch 0.02
#define Ki_RollPitch 0.00002*/
//#define Kp_RollPitch 0.02
//#define Ki_RollPitch 0.00002
#define p_RollPitch 0.02
#define i_RollPitch 0.00002
float Kp_RollPitch =  p_RollPitch; 
float Ki_RollPitch =  i_RollPitch;

#define Kp_Yaw 1.2 
#define Ki_Yaw 0.00002

#define CyclemS 10
#define Freq ((1000/CyclemS)/2) 
#define FilterA	((long)CyclemS*256)/(1000/(6*Freq)+CyclemS)

#define CORRECT_DRIFT 1

#define PRINT_EULER   1
#define PRINT_ANALOGS 0
#define PRINT_AUX     1
#define PRINT_DCM     0
#define PRINT_VECTOR  0
#define PRINT_DEBUG   0

#define PRINT_UAVX_READABLE 0
#define USING_UAVX          0
#define FORCE_ACC_NEUTRALS  0

#define EXTENDED 1 // includes renormalisation recovery from V1.0

#define STATUS_LED 13 


#define SCR_WID 16 // the LED panel size

//-----------------------------------------------------------------------

const  char  AccNeutralForced[3] = { 0,0,0 }; // determine neutrals in aircraft setup and load here 
const byte Map[3]    = {  1,  2,  0 };             // Map the ADC channels gyro from z,x,y to x,y,z
const int AccSign[3] = {  1,  1,  1 };
const int MagSign[3] = { -1, -1, -1 }; 

float   G_Dt = 0.01; // DCM integration time 100Hz if possible

long    ClockmSp;
long    PeriodmS;
long    ClockmS;
byte    CompassInterval = 0;
byte    RotInterval = 0;

int     Gyro[3], GyroADC[3], GyroNeutral[3];
int     Acc[3], AccADC[3], AccNeutral[3];
char    AccNeutralUse[3];   

int     Mag[3], MagADC[3];
float   MagHeading;
float   GMagnitude;
float   Rot;
//float   Slip;
static float   Velocity;
float   Roll, Pitch, Yaw;


float   RollPitchError[3] = {0,0,0}; 
float   YawError[3] = {0,0,0};

byte i;
char ch;


void Initialise()
{
  static byte i, c;

  for( i = 0; i < 32; i++ )
  {
    GetGyro();
    GetAccelerometer();
    for( c = 0; c < 3; c++ )
    {
      GyroNeutral[c] += GyroADC[c];
      AccNeutral[c] += AccADC[c];
    }
    delay(20);
  }

  for( c = 0; c < 3; c++ )
  {
    GyroNeutral[c] = GyroNeutral[c]/32.0;
    AccNeutral[c] = ( AccNeutral[c] + 16 ) >> 5;
  }

  AccNeutral[2] -= GRAVITY * AccSign[2];

/*#if USING_UAVX == 0 
  for ( i = 0 ; i < 3 ; i++ )
    Serial.println(GyroNeutral[i]);
  for ( i = 0 ; i < 3 ; i++ )
    Serial.println(AccNeutral[i]);
#endif // USING_UAVX*/

  for ( i = 0 ; i < 3 ; i++)
#if FORCE_ACC_NEUTRALS
    AccNeutralUse[i] = AccNeutralForced[i]; 
#else
  AccNeutralUse[i] = AccNeutral[i];  
#endif // FORCE_ACC_NEUTRALS

  ClockmSp = millis();

} // Initialise

void setup()
{
  Serial.begin(115200);
  ADCReference(DEFAULT); 

  InitADCBuffers();
  InitADC();
  InitI2C();
  InitAccelerometers();
  GetAccelerometer();
  InitMagnetometer();

#if USING_UAVX == 0
  Serial.println("Sparkfun 9DOF Razor AHRS - LEDHUD");
#endif // USING_UAVX

  Initialise();

} // setup

void DoIteration(void)
{
  ClockmSp = ClockmS;
  G_Dt = (float)PeriodmS / 1000.0;

  GetGyro(); 
  GetAccelerometer();    

  if ( ++CompassInterval > 5) // compass 1/5 rate
  {
    CompassInterval = 0;
    GetMagnetometer();
    ComputeHeading();
  }

  MUpdate(); 
  Normalize();
  
  DriftCorrection();
  EulerAngles(); 
  RateOfTurn();
  SendAttitude();  
  //SendLEDpanel();
} // DoIteration

void loop()
{
  // free runs at ~160Hz
  ClockmS = millis();
  PeriodmS = ClockmS - ClockmSp;
  if  ( PeriodmS >= CyclemS )
    DoIteration();

} // Main




